#include <stdint.h>
#include "catalog.h"
#define REG(off) (*(volatile uint32_t *)(0xf8100000u+(off)))
#define COUNT(a) (sizeof(a)/sizeof((a)[0]))
static volatile uint32_t completions;
static uint32_t ticks(void) { return REG(0x30); }
static void osd_char(uint32_t index,uint32_t ch) { REG(0x0c)=(index<<8)|ch; }
static void osd_init(void) {
  static const char text[]="1280X720FPS:00.0";
  for(uint32_t i=0;i<16;++i)osd_char(i,(uint32_t)text[i]);
}
static void osd_fps(uint32_t fps) {
  uint32_t tens=0,ones=0;
  if(fps>999)fps=999;
  while(fps>=100) {fps-=100;++tens;}
  while(fps>=10) {fps-=10;++ones;}
  osd_char(12,'0'+tens);osd_char(13,'0'+ones);osd_char(14,'.');osd_char(15,'0'+fps);
}
static void fail(uint32_t code) {
  REG(0x08)=0; REG(0x68)=0; REG(0x78)=0xee000000u|code;
  for (;;) __asm__ volatile ("nop");
}
static void camera_init(void) {
  uint32_t t=ticks();
  while ((uint32_t)(ticks()-t)<200000u) {}
  for(uint32_t i=0;i<COUNT(camera_table);++i) {
    REG(0x50)=camera_table[i]; t=ticks();
    for (;;) {
      uint32_t s=REG(0x54);
      if(s&4u)fail(0x100u+i);
      if((s&3u)==2u && ((s>>8)&255u)==i+1u)break;
      if((uint32_t)(ticks()-t)>3000000u)fail(0x200u+i);
    }
  }
  REG(0x54)=8;
  if(!(REG(0x54)&8u))fail(0x300);
}
static void load_models(void) {
  uint32_t k=0; REG(0x58)=0;
  for(uint32_t i=0;i<1152;++i) {
    uint32_t v=0;
    if(k<COUNT(model_words)&&model_words[k].index==i)v=model_words[k++].value;
    REG(0x5c)=v;
  }
  if(k!=COUNT(model_words)||REG(0x58)!=1152)fail(0x400);
  REG(0x60)=5;
  if((REG(0x60)&7u)!=5u)fail(0x401);
}
void __attribute__((interrupt("machine"),aligned(4))) accelerator_isr(void) {
  uint32_t cause; __asm__ volatile("csrr %0,mcause":"=r"(cause));
  if(cause!=0x8000000bu)fail(0x500);
  if(REG(0x6c)&1u) { REG(0x6c)=1; ++completions; }
}
int main(void) {
  REG(0x78)=0xa8000001u; REG(0x08)=0; REG(0x68)=0;
  osd_init(); camera_init(); load_models();
  uint32_t vector=(uint32_t)(uintptr_t)&accelerator_isr;
  __asm__ volatile("csrw mtvec,%0"::"r"(vector):"memory");
  __asm__ volatile("csrw mie,%0"::"r"(0x800u):"memory");
  REG(0x6c)=1; REG(0x68)=1;
  __asm__ volatile("csrsi mstatus,8"::: "memory");
  REG(0x64)=0; REG(0x08)=1;
  if(REG(0x08)!=1)fail(0x600);
  uint32_t style=0,layout=0,last=completions,last_tick=ticks(),last_fps=0xffffffffu;
  for (;;) {
    uint32_t fps=REG(0x0c);
    if(fps!=last_fps) {osd_fps(fps);last_fps=fps;}
    uint32_t ev=REG(0x4c);
    if(ev&3u) {
      REG(0x4c)=ev&3u;
      if(ev&1u)layout=(layout+1u)&3u;
      if(ev&2u) { ++style; if(style==3)style=0; }
      REG(0x64)=(style<<2)|layout;
    }
    if(ev&4u) {
      uint32_t seq=REG(0x70),requested=REG(0x74);
      if(seq==REG(0x70)&&requested<3u) {
        style=requested; if(layout==0)layout=1;
        REG(0x64)=(style<<2)|layout; REG(0x7c)=seq;
      }
    }
    if(REG(0x10)&0x1f0u)fail(0x700|(REG(0x10)&0x1f0u));
    uint32_t now=completions;
    if(now!=last) {last=now;last_tick=ticks();}
    else if((uint32_t)(ticks()-last_tick)>200000000u)fail(0x800);
    REG(0x78)=0xa8000000u|(now&0x00ffffffu);
  }
}
