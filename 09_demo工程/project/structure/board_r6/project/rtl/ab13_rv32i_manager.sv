// Independent candidate: in-order, multi-cycle RV32I management processor.
// A single-port synchronous register RAM trades cycles for area. The wrapper
// retains original Sapphire UART/SPI peripherals; no cache/JTAG/DDR
// master in this core. R8 adds machine CSRs and an external completion IRQ.
module ab13_rv32i_manager #(
 parameter MEM_FILE="cpu_boot.mem", parameter WORDS=2048, parameter PADDR_WIDTH=16,EXTENDED_MMIO=0,
 parameter [31:0] RESET_PC=32'hf9000000
)(
 input wire clk,rstn,input wire irq,
 output wire [PADDR_WIDTH-1:0] paddr,output wire psel,penable,pwrite,
 output wire [31:0] pwdata,input wire pready,pslverr,input wire [31:0] prdata,
 output reg trap,output reg [3:0] trap_cause,output reg [31:0] trap_value,
 output reg retire,output reg [31:0] retire_pc,retire_insn,
 output reg [4:0] retire_rd,output reg [31:0] retire_value,
 output wire [31:0] debug_pc
);
 localparam FETCH=0,DECODE=1,READ_A=2,READ_B=3,EXECUTE=4,WRITEBACK=5,
            MEMORY=6,LOAD_DONE=7,APB_SETUP=8,APB_ACCESS=9,HALT=10,SHIFT=11;
 reg [3:0] state;reg [4:0] shift_count;reg shift_left,shift_arithmetic;
 reg [31:0] pc,ir,a;
 // A25 observation only: current instruction PC; sticky on CPU trap.
 assign debug_pc=pc;
 reg [31:0] wb_value,next_pc;
 reg [4:0] wb_rd;
 reg [31:0] address,store_value;
 reg [2:0] mem_funct;
 reg mem_write;
 // Four independent byte lanes avoid variable partial writes, which failed
 // Efinity RAM decomposition and expanded the previous 2 KiB RAM into FFs.
 (* syn_ramstyle="block_ram" *) reg [31:0] rf[0:31];
 wire [31:0] ram_q;reg [31:0] rf_q;
 wire [4:0] rf_address=state==WRITEBACK ? wb_rd :
                              state==READ_A ? ir[19:15] : ir[24:20];
 always @(posedge clk)begin
  if(state==WRITEBACK && wb_rd!=0 && rstn)rf[rf_address]<=wb_value;
  else rf_q<=rf[rf_address];
 end
 wire [31:0] b=ir[24:20]==0 ? 32'd0 : rf_q;
 localparam AW=$clog2(WORDS);
 wire [AW-1:0] ram_address=state==FETCH ? pc[AW+1:2] : address[AW+1:2];
 wire in_ram=address>=RESET_PC && address<RESET_PC+WORDS*4;
 wire in_apb=address[31:16]==16'hf810 || (EXTENDED_MMIO &&
   ((address[31:6]==(32'hf8010000>>6)) ||
    (address[31:12]==(32'hf8014000>>12))));
 wire ram_write=rstn && state==MEMORY && in_ram && mem_write;
 wire [3:0] byte_en=mem_funct==0 ? (4'b0001<<address[1:0]) :
                    mem_funct==1 ? (4'b0011<<{address[1],1'b0}) : 4'b1111;
 wire [31:0] aligned_store=store_value<<({address[1:0],3'b000});
 genvar lane;
 generate for(lane=0;lane<4;lane=lane+1)begin:boot_lane
  (* syn_ramstyle="block_ram" *) reg [7:0] mem[0:WORDS-1];
  reg [7:0] q;
  // A26: initialize each physical byte memory directly. Indirect initial
  // copies from another initialized memory silently mapped to all zero in
  // Efinity 2026.1 despite passing behavioral simulation.
  if(lane==0)begin:load initial $readmemh({MEM_FILE,".lane0"},mem);end
  else if(lane==1)begin:load initial $readmemh({MEM_FILE,".lane1"},mem);end
  else if(lane==2)begin:load initial $readmemh({MEM_FILE,".lane2"},mem);end
  else begin:load initial $readmemh({MEM_FILE,".lane3"},mem);end
  always @(posedge clk)begin
   if(ram_write && byte_en[lane])mem[ram_address]<=aligned_store[lane*8+:8];
   else q<=mem[ram_address];
  end
  assign ram_q[lane*8+:8]=q;
 end endgenerate
 assign psel=rstn && (state==APB_SETUP || state==APB_ACCESS);
 assign penable=rstn && state==APB_ACCESS;
 assign pwrite=mem_write;
 assign paddr={address[31:2],2'b00};
 assign pwdata=store_value;
 wire [31:0] imm_i={{20{ir[31]}},ir[31:20]};
 wire [31:0] imm_s={{20{ir[31]}},ir[31:25],ir[11:7]};
 wire [31:0] imm_b={{19{ir[31]}},ir[31],ir[7],ir[30:25],ir[11:8],1'b0};
 wire [31:0] imm_j={{11{ir[31]}},ir[31],ir[19:12],ir[20],ir[30:21],1'b0};
 wire [31:0] operand=ir[6:0]==7'h13 ? imm_i : b;
 wire [31:0] effective_address=a+(ir[6:0]==7'h23 ? imm_s : imm_i);
 reg [31:0] alu,branch_target;
 reg legal,taken;
 reg [31:0] mtvec,mepc,mcause;
 reg mstatus_mie,mstatus_mpie,mie_meie;
 reg [31:0] csr_read,csr_new;reg csr_legal;
 wire csr_insn=ir[6:0]==7'h73 && ir[14:12]!=0;
 wire [31:0] csr_operand=ir[14] ? {27'd0,ir[19:15]} : a;
 wire csr_write=ir[13:12]==1 || ir[19:15]!=0;
 always @*begin
  csr_legal=1;csr_read=0;
  case(ir[31:20])
   12'h300:csr_read={24'd0,mstatus_mpie,3'd0,mstatus_mie,3'd0};
   12'h304:csr_read={20'd0,mie_meie,11'd0};
   12'h305:csr_read=mtvec;
   12'h341:csr_read=mepc;
   12'h342:csr_read=mcause;
   12'h344:csr_read={20'd0,irq,11'd0};
   default:csr_legal=0;
  endcase
  case(ir[13:12])
   1:csr_new=csr_operand;
   2:csr_new=csr_read|csr_operand;
   3:csr_new=csr_read&~csr_operand;
   default:csr_new=csr_read;
  endcase
 end
 always @* begin
  alu=0;legal=1;taken=0;branch_target=pc+imm_b;
  case(ir[6:0])
   7'h37:alu={ir[31:12],12'b0};
   7'h17:alu=pc+{ir[31:12],12'b0};
   7'h6f:begin alu=pc+4;taken=1;branch_target=pc+imm_j;end
   7'h67:begin alu=pc+4;taken=1;branch_target=(a+imm_i)&32'hfffffffe;legal=ir[14:12]==0;end
   7'h63:case(ir[14:12])
    0:taken=a==b;1:taken=a!=b;
    4:taken=$signed(a)<$signed(b);5:taken=$signed(a)>=$signed(b);
    6:taken=a<b;7:taken=a>=b;
    default:legal=0;
   endcase
   7'h13,7'h33:begin
    if(ir[6:0]==7'h33)legal=ir[31:25]==0 ||
                            (ir[31:25]==7'h20 && (ir[14:12]==0 || ir[14:12]==5));
    case(ir[14:12])
     0:alu=(ir[6:0]==7'h33 && ir[30]) ? a-b : a+operand;
     1:begin alu=0;if(ir[6:0]==7'h13)legal=ir[31:25]==0;end
     2:alu={31'd0,$signed(a)<$signed(operand)};
     3:alu={31'd0,a<operand};
     4:alu=a^operand;
     5:begin
      alu=0;
      if(ir[6:0]==7'h13)legal=ir[31:25]==0 || ir[31:25]==7'h20;
     end
     6:alu=a|operand;7:alu=a&operand;
    endcase
   end
   7'h73:legal=csr_legal && csr_insn;
   7'h03:legal=ir[14:12]==0 || ir[14:12]==1 || ir[14:12]==2 || ir[14:12]==4 || ir[14:12]==5;
   7'h23:legal=ir[14:12]<=2;
   // Base FENCE is a NOP here: no older transaction can remain outstanding.
   7'h0f:legal=ir[14:12]==0;
   default:legal=0;
  endcase
 end
 function [31:0] loaded(input [31:0] data,input [2:0] funct,input [1:0] byte_offset);
  reg [31:0] shifted;
  begin
   shifted=data>>(byte_offset*8);
   case(funct)
    0:loaded={{24{shifted[7]}},shifted[7:0]};
    1:loaded={{16{shifted[15]}},shifted[15:0]};
    2:loaded=data;
    4:loaded={24'd0,shifted[7:0]};
    5:loaded={16'd0,shifted[15:0]};
    default:loaded=0;
   endcase
  end
 endfunction
 task fail(input [3:0] cause,input [31:0] value);
  begin trap<=1;trap_cause<=cause;trap_value<=value;state<=HALT;end
 endtask
 task complete(input [4:0] rd,input [31:0] value,input [31:0] target);
  begin
   retire<=1;retire_pc<=pc;retire_insn<=ir;retire_rd<=rd;
   retire_value<=rd==0 ? 32'd0 : value;pc<=target;state<=FETCH;
  end
 endtask
 always @(posedge clk)begin
  if(!rstn)begin
   shift_count<=0;shift_left<=0;shift_arithmetic<=0;state<=FETCH;pc<=RESET_PC;ir<=0;a<=0;next_pc<=0;wb_rd<=0;wb_value<=0;
   address<=0;store_value<=0;mem_funct<=0;mem_write<=0;
   trap<=0;trap_cause<=0;trap_value<=0;mtvec<=RESET_PC;mepc<=0;mcause<=0;mstatus_mie<=0;mstatus_mpie<=0;mie_meie<=0;
   retire<=0;retire_pc<=0;retire_insn<=0;retire_rd<=0;retire_value<=0;
  end else begin
   retire<=0;
   case(state)
    FETCH:if(irq && mstatus_mie && mie_meie)begin
            mepc<=pc;mcause<=32'h8000000b;mstatus_mpie<=mstatus_mie;mstatus_mie<=0;
            pc<={mtvec[31:2],2'b00};
           end else if(pc[1:0]!=0)fail(0,pc);
           else if(pc<RESET_PC || pc>=RESET_PC+WORDS*4)fail(1,pc);
          else state<=DECODE;
    DECODE:begin ir<=ram_q;state<=READ_A;end
    READ_A:state<=READ_B;
    READ_B:begin a<=ir[19:15]==0 ? 32'd0 : rf_q;state<=EXECUTE;end
    EXECUTE:begin
     if(ir==32'h30200073)begin
       mstatus_mie<=mstatus_mpie;mstatus_mpie<=1;complete(0,0,mepc);
      end else if(csr_insn && csr_legal)begin
       if(csr_write)case(ir[31:20])
        12'h300:begin mstatus_mie<=csr_new[3];mstatus_mpie<=csr_new[7];end
        12'h304:mie_meie<=csr_new[11];
        12'h305:mtvec<={csr_new[31:2],2'b00};
        12'h341:mepc<={csr_new[31:2],2'b00};
        12'h342:mcause<=csr_new;
        default:;
       endcase
       wb_value<=csr_read;wb_rd<=ir[11:7];next_pc<=pc+4;state<=WRITEBACK;
      end else if(ir==32'h00000073)fail(8,0); // Environment call: machine-only harness.
     else if(ir==32'h00100073)fail(3,0); // Architectural breakpoint.
     else if(!legal)fail(2,ir);
     else if(taken && branch_target[1:0]!=0)fail(0,branch_target);
     else if((ir[6:0]==7'h13 || ir[6:0]==7'h33) &&
              (ir[14:12]==1 || ir[14:12]==5))begin
      wb_rd<=ir[11:7];wb_value<=a;next_pc<=pc+4;
      shift_count<=operand[4:0];shift_left<=ir[14:12]==1;
      shift_arithmetic<=ir[30] && ir[14:12]==5;
      state<=operand[4:0]==0 ? WRITEBACK : SHIFT;
     end else if(ir[6:0]==7'h03 || ir[6:0]==7'h23)begin
      if((ir[13:12]==1 && effective_address[0]) ||
         (ir[13:12]==2 && effective_address[1:0]!=0))fail(ir[6:0]==7'h23 ? 6 : 4,effective_address);
      else begin
       address<=effective_address;store_value<=b;mem_funct<=ir[14:12];
       mem_write<=ir[6:0]==7'h23;wb_rd<=ir[11:7];next_pc<=pc+4;state<=MEMORY;
      end
     end else if(ir[6:0]==7'h63 || ir[6:0]==7'h0f)complete(0,0,taken ? branch_target : pc+4);
     else begin wb_value<=alu;wb_rd<=ir[11:7];next_pc<=taken ? branch_target : pc+4;state<=WRITEBACK;end
    end
    SHIFT:begin
     wb_value<=shift_left ? {wb_value[30:0],1'b0} :
                           {shift_arithmetic&&wb_value[31],wb_value[31:1]};
     shift_count<=shift_count-1'b1;
     if(shift_count==1)state<=WRITEBACK;
    end
    WRITEBACK:complete(wb_rd,wb_value,next_pc);
    MEMORY:begin
     if(in_ram)begin
      if(mem_write)complete(0,0,next_pc);
      else state<=LOAD_DONE;
     end else if(in_apb && mem_funct==2)state<=APB_SETUP;
     else fail(mem_write ? 7 : 5,address);
    end
    LOAD_DONE:begin wb_value<=loaded(ram_q,mem_funct,address[1:0]);state<=WRITEBACK;end
    APB_SETUP:state<=APB_ACCESS;
    APB_ACCESS:if(pready)begin
     if(pslverr)fail(mem_write ? 7 : 5,address);
     else if(mem_write)complete(0,0,next_pc);
     else begin wb_value<=prdata;state<=WRITEBACK;end
    end
    HALT:state<=HALT;
    default:fail(2,ir);
   endcase
  end
 end
endmodule
