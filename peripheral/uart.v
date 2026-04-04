
`include "project.vh"

// valojaban BIT_TIME + 1 a bitido, javitani kell

`define HALF_BIT_TIME	 (`UART_BIT_TIME / 2)

module uart(
	input clk,
	input rst,

	input txen,
	input rx,
	input [7:0] txdata,
	output reg tx,
	output reg rxen,
	output txbusy,
	output reg [7:0] rxdata
);

reg otxen, orx, rx1, rx2;
reg [3:0] txstate;
reg [3:0] rxstate;
reg [9:0] txcnt, rxcnt;
reg [7:0] out;
reg [7:0] txsh;
reg [7:0] rxsh, rxdata0;
reg [3:0] rxwait;

reg [1:0] dcnt, dstate;

assign txbusy = (txstate != 0);

// --------------------------- RX state machine ----------------------

always @(posedge clk or negedge rst)
if (~rst)
    {rxen, rxdata, rxdata0, rxstate, rxcnt, orx, rxsh, rx1, rx2} <= 0;
else
begin
		rx1 <= rx;
		rx2 <= rx1;
    orx <= rx2;

    if (rxcnt == `UART_BIT_TIME || (rxstate == 0 && rx2 == 0 && orx == 1))
	rxcnt <= 0;
    else
	rxcnt <= rxcnt + 1;

    case (rxstate)
    0:  begin
	       if (rx2 == 0 && orx == 1)
			   rxstate <= 1;					// start bit
        end

    1:  begin

	       if (rxcnt == `HALF_BIT_TIME && rx2 == 1)
			   rxstate <= 0;					// invalid start bit

	       if (rxcnt == (`UART_BIT_TIME - 1))
			 begin
			   rxsh <= 1;
			   rxstate <= 2;
			 end
        end

    2:  begin
	       if (rxcnt == `HALF_BIT_TIME) // && rxsh != 0)
			 begin
				rxdata0 <= {rx2, rxdata0[7:1]};
				rxsh <= {rxsh[6:0], 1'b0};
			 end

			 if (rxcnt == (`UART_BIT_TIME - 1) && rxsh == 0)
  		    begin
			   rxstate <= 0;
				 rxdata <= rxdata0;
		     rxen <= rxen ^ 1;
			 end

		  end
  endcase
end

// --------------------------- TX state machine ----------------------

always @(posedge clk or negedge rst)
if (~rst)
begin
  {txcnt} <= 0;
end else
begin
  if (txen != otxen || txcnt == `UART_BIT_TIME)
    txcnt <= 0;
  else
    txcnt <= txcnt + 1;
end

always @(posedge clk or negedge rst)
if (~rst)
begin
  tx <= 1;
  {otxen, txstate} <= 0;
end else
begin
  otxen <= txen;

  case (txstate)
    0:  begin
	   if (txen != otxen)
		begin
		  txstate <= 1;
		  tx <= 0;		// start bit
		end else
		  tx <= 1;
	   end

	1:  begin
	      if (txcnt == (`UART_BIT_TIME - 1))
			begin
			  txstate <= 2;
			  out <= txdata;
			  txsh <= 1;
			end
	    end

   2:	begin
	    if (txcnt == (`UART_BIT_TIME - 1))
	    begin
		out <= {1'b1, out[7:1]};
		txsh <= {txsh[6:0], 1'b0};
	    end else
	    begin
		tx <= out[0];
	    end

	    if (txsh == 0)
		txstate <= 3;
	end

   3:  begin
		 tx <= 1;

	    if (txcnt == (`UART_BIT_TIME - 1))		// only if 1 stop bit required
	      txstate <= 0;
	    end
  endcase
end

initial
  begin
    {tx, otxen, rxen, rxdata, txstate, rxstate, out, txsh, rxsh, txcnt} <= 0;
  end

endmodule
