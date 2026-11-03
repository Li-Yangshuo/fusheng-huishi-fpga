// Common-clock only. Three logical FWFT queues share one 128-bit simple-dual-
// port RAM because the AXI engine can produce at most one read beat per cycle.
// Capacity remains S=32, A=32, B=16 RAM words, plus two head words per queue.
// Two head registers reserve space for the synchronous RAM result in flight.
// Round-robin reads prevent a stalled queue from blocking the other queues.
`timescale 1ns/1ps
module nst_shared_readq (
    input wire clk, rst_n,
    input wire [2:0] we,
    input wire [383:0] wd,
    output wire [2:0] full,
    input wire [2:0] pop,
    output wire [383:0] rd,
    output wire [2:0] empty,
    output wire [5:0] a_wp, a_rp, a_wc
);
    (* ram_style = "block" *) reg [127:0] mem [0:127];
    reg [5:0] wp [0:2], rp [0:2];
    reg [127:0] head [0:2], tail [0:2];
    reg [1:0] count [0:2];
    reg [127:0] ram_out;
    reg pending;
    reg [1:0] pending_q, rr;
    wire [2:0] take, accept;
    wire [2:0] request;
    genvar g;
    generate for(g=0;g<3;g=g+1) begin: q
        wire [5:0] occupied = wp[g]-rp[g];
        assign full[g] = occupied == ((g==2)?16:32);
        assign empty[g] = count[g]==0;
        assign rd[g*128+:128] = head[g];
        assign take[g] = pop[g] && !empty[g];
        assign accept[g] = we[g] && !full[g];
        // count plus the result retiring now, less the head popped now,
        // must leave a slot for the read being issued now.
        wire arriving = pending && pending_q==g;
        wire [2:0] reserved = {1'b0,count[g]} + arriving - take[g];
        assign request[g] = occupied!=0 && reserved<2;
    end endgenerate

    reg issue;
    reg [1:0] sel;
    always @* begin
        issue=1'b0; sel=0;
        case(rr)
        0: if(request[0])begin issue=1;sel=0;end
           else if(request[1])begin issue=1;sel=1;end
           else if(request[2])begin issue=1;sel=2;end
        1: if(request[1])begin issue=1;sel=1;end
           else if(request[2])begin issue=1;sel=2;end
           else if(request[0])begin issue=1;sel=0;end
        default:
           if(request[2])begin issue=1;sel=2;end
           else if(request[0])begin issue=1;sel=0;end
           else if(request[1])begin issue=1;sel=1;end
        endcase
    end
    wire write_en = |accept;
    wire [1:0] write_q = accept[0]?0:accept[1]?1:2;
    wire [6:0] write_addr = {write_q, (write_q==2 ? {1'b0,wp[2][3:0]} : wp[write_q][4:0])};
    wire [6:0] read_addr = {sel, (sel==2 ? {1'b0,rp[2][3:0]} : rp[sel][4:0])};
    // No reset on RAM data/port registers: infer a single shared RAM bank.
    always @(posedge clk) begin
        if(rst_n && write_en) mem[write_addr] <= wd[write_q*128+:128];
        if(rst_n && issue) ram_out <= mem[read_addr];
    end
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            pending<=0; pending_q<=0; rr<=0;
            for(i=0;i<3;i=i+1)begin wp[i]<=0;rp[i]<=0;count[i]<=0;end
        end else begin
            pending<=issue;
            if(issue)begin
                pending_q<=sel; rr<=sel==2?0:sel+1'b1;
                rp[sel]<=rp[sel]+1'b1;
            end
            for(i=0;i<3;i=i+1)begin
                if(accept[i])wp[i]<=wp[i]+1'b1;
                case({pending && pending_q==i,take[i]})
                2'b01: begin head[i]<=tail[i];count[i]<=count[i]-1'b1;end
                2'b10: begin
                    if(count[i]==0)head[i]<=ram_out;else tail[i]<=ram_out;
                    count[i]<=count[i]+1'b1;
                end
                2'b11: begin
                    if(count[i]==1)head[i]<=ram_out;
                    else begin head[i]<=tail[i];tail[i]<=ram_out;end
                end
                default: ;
                endcase
            end
        end
    end
    assign a_wp=wp[1]; assign a_rp=rp[1]; assign a_wc=wp[1];
`ifndef SYNTHESIS
    always @(posedge clk) if(rst_n)begin
        if((we & (we-1'b1))!=0)$fatal(1,"shared read queue requires one AXI writer");
        if(|(we & full))$fatal(1,"shared read queue write while full");
        for(integer k=0;k<3;k=k+1)begin
            if(count[k]>2)$fatal(1,"head queue overflow");
            if(pending && pending_q==k && !take[k] && count[k]==2)
                $fatal(1,"unreserved RAM result");
        end
    end
`endif
endmodule
