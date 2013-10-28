/*
 * $File: com2flash.v
 * $Date: Mon Oct 28 23:52:33 2013 +0800
 * $Author: jiakai <jia.kai66@gmail.com>
 */

/*
* protocol:
* s: server (PC)
* c: client (our board)
* s -> c:
*	CMD_WRITE
*		s -> c:
*			3 bytes start_addr, MSB to LSB
*			3 bytes end_addr, MSB to LSB
*		c -> s:
*			1 byte, checksum
*		s -> s:
*			2 * (start_addr - end_addr) bytes, the data
*			for each word, MSB to LSB order
*		c -> s:
*			1 byte, checksum
*		goto idle state
* s -> c:
*	CMD_READ
*		s -> c:
*			3 bytes start_addr, MSB to LSB
*			3 bytes end_addr, MSB to LSB
*		c -> s:
*			1 byte, checksum
*		c -> s
*			2 * (start_addr - end_addr) bytes, the data
*			for each word, MSB to LSB order
*		c -> s:
*			1 byte, checksum
*
* output:
*	segdisp: number of 4k blocks
*/

module com2flash
	#(parameter FLASH_ADDR_SIZE = 22)
	(
	input clk,
	input rst,
	output [15:0] led,
	output [0:6] segdisp0,
	output [0:6] segdisp1,
	inout [7:0] baseram_data,
	output baseram_oe,
	output baseram_ce,
	output baseram_we,
	output reg uart_enable_recv,
	output reg uart_TxD_start,
	input uart_TxD_busy,
	input uart_RxD_data_ready,
	input uart_RxD_waiting_data,
	output uart_rst,
	output [FLASH_ADDR_SIZE:0] flash_addr,
	inout [15:0] flash_data,
	output [7:0] flash_ctl);

	localparam CMD_WRITE = 8'hf3, CMD_READ = 8'h2a;

	reg [19:0] frame_cnt;
	reg [3:0] frame_looper;

	// display number of 4k blocks
	/*
	digseg_driver disp_fc_high(.data(frame_cnt[19:16]), .seg(segdisp1));
	digseg_driver disp_fc_low(.data(frame_cnt[15:12]), .seg(segdisp0));
	*/
	reg [7:0] data_debug_disp;	// XXX
	digseg_driver disp_fc_high(.data(data_debug_disp[7:4]), .seg(segdisp1));
	digseg_driver disp_fc_low(.data(data_debug_disp[3:0]), .seg(segdisp0));

	assign uart_rst = ~rst;
	assign baseram_oe = 1;
	assign baseram_ce = 1;
	assign baseram_we = 1;

	reg [7:0] data_to_com, data_to_com_cache;
	wire [7:0] data_from_com = baseram_data[7:0];

	reg [7:0] checksum;
	reg [FLASH_ADDR_SIZE-1:0] start_addr, end_addr, addr_to_flash;
	wire [FLASH_ADDR_SIZE-1:0] start_addr_next = start_addr + 1'b1;

	reg [47:0] comdata_shift;
	reg [2:0] comdata_shift_cnt;
	wire [2:0] comdata_shift_cnt_next = comdata_shift_cnt + 1'b1;

	wire [7:0] checksum_init = 8'h23;

	wire flash_busy;
	wire [15:0] data_from_flash;
	reg enable_flash_write, enable_flash_read;

	flash_driver #(.FLASH_ADDR_SIZE(FLASH_ADDR_SIZE)) flash_driver_inst(
		.clk(~clk),	// invert clock to ensuare stable signal on rising edge
		.addr(addr_to_flash),
		.data_in(comdata_shift[15:0]), .data_out(data_from_flash),
		.enable_read(enable_flash_read),
		.enable_write(enable_flash_write),
		.enable_erase(1'b0),
		.busy(flash_busy),
		.flash_addr(flash_addr), .flash_data(flash_data),
		.flash_ctl(flash_ctl));

	localparam
		IDLE = 4'b0000,
		RECV_META = 4'b0001,
		META_ACK = 4'b0011,
		WRITE_INIT_TRANSFER = 4'b0010,
		WRITE_RECV_DATA = 4'b0110,
		WRITE_SEND_DATA_ACK = 4'b0111,
		READ_INIT_TRANSFER = 4'b0101,
		READ_READ_FLASH = 4'b0100,
		READ_SEND_HIGH = 4'b1100,
		READ_SEND_LOW = 4'b1101,
		WAITING_UART_SEND = 4'b1111,
		WAITING_UART_SEND_1 = 4'b1110,
		ERROR = 4'b1010;

	reg [3:0] state = IDLE, state_after_meta_ack, state_after_uart_sent;

	reg err_flash_too_slow = 0;

	assign led = {state, frame_looper,
		1'b0, err_flash_too_slow, uart_RxD_waiting_data,
		uart_TxD_busy, uart_RxD_data_ready,
		enable_flash_read, enable_flash_write, flash_busy};
	assign baseram_data = uart_enable_recv ? {8{1'bz}} : data_to_com;

	always @(posedge clk) begin
		if (~rst) begin
			frame_cnt <= 0;
			frame_looper <= 0;
		end
		else if (uart_enable_recv & uart_RxD_data_ready) begin
			comdata_shift <= {comdata_shift[39:0], data_from_com};
			frame_cnt <= frame_cnt + 1'b1;
			frame_looper <= {frame_looper[2:0], !frame_looper[2:0]};
		end
	end

	always @(posedge clk) begin
		if (!rst)
			state <= IDLE;
		else case (state)
			IDLE: begin
				uart_enable_recv <= 1;
				uart_TxD_start <= 0;
				checksum <= checksum_init;
				comdata_shift_cnt <= 0;
				enable_flash_write <= 0;
				enable_flash_read <= 0;
				if (uart_RxD_data_ready) begin
					if (data_from_com == CMD_WRITE) begin
						state <= RECV_META;
						state_after_meta_ack <= WRITE_INIT_TRANSFER;
					end else if (data_from_com == CMD_READ) begin
						state <= RECV_META;
						state_after_meta_ack <= READ_INIT_TRANSFER;
					end
				end
			end

			RECV_META:
				if (uart_RxD_data_ready) begin
					comdata_shift_cnt <= comdata_shift_cnt_next;
					checksum <= checksum ^ data_from_com;
					if (comdata_shift_cnt_next == 6)
						state <= META_ACK;
				end
			META_ACK: begin
				start_addr <= comdata_shift[FLASH_ADDR_SIZE-1+24:24];
				end_addr <= comdata_shift[FLASH_ADDR_SIZE-1:0];
				data_to_com <= checksum;
				uart_enable_recv <= 0;
				uart_TxD_start <= 1;
				checksum <= checksum_init;
				state <= WAITING_UART_SEND;
				state_after_uart_sent <= state_after_meta_ack;
			end

			WRITE_INIT_TRANSFER: begin
				uart_enable_recv <= 1;
				uart_TxD_start <= 0;
				comdata_shift_cnt[0] <= 0;
				state <= WRITE_RECV_DATA;
				enable_flash_read <= 0;
			end
			WRITE_RECV_DATA: begin
				if (uart_RxD_data_ready) begin
					if (flash_busy) begin
						state <= ERROR;
						err_flash_too_slow <= 1;
					end
					comdata_shift_cnt[0] <= comdata_shift_cnt_next[0];
					enable_flash_write <= comdata_shift_cnt[0]; 
					if (comdata_shift_cnt[0]) begin
						addr_to_flash <= start_addr;
						checksum <= checksum ^ data_from_com ^
							comdata_shift[7:0];

						if (start_addr_next == end_addr)
							state <= WRITE_SEND_DATA_ACK;
						start_addr <= start_addr_next;
					end 
				end else
					enable_flash_write <= 0;
			end
			WRITE_SEND_DATA_ACK: begin
				enable_flash_write <= 0;
				if (!flash_busy) begin
					data_to_com <= checksum;
					uart_enable_recv <= 0;
					uart_TxD_start <= 1;
					state_after_uart_sent <= IDLE;
					state <= WAITING_UART_SEND;
				end
			end

			READ_INIT_TRANSFER: begin
				uart_TxD_start <= 0;
				addr_to_flash <= start_addr;
				enable_flash_read <= 1;
				enable_flash_write <= 0;
				state <= READ_READ_FLASH;
			end
			READ_READ_FLASH: begin
				if (!flash_busy) begin
					checksum <= checksum ^ 
						data_from_flash[15:8] ^ data_from_flash[7:0];
					data_to_com <= data_from_flash[15:8];
					data_to_com_cache <= data_from_flash[7:0];
					data_debug_disp <= data_from_flash[7:0];	// XXX
					uart_TxD_start <= 1;
					state_after_uart_sent <= READ_SEND_HIGH;
					state <= WAITING_UART_SEND;
					// parallel loading next word
					start_addr <= start_addr_next; 
					// addr_to_flash <= start_addr_next; XXX
				end
			end
			READ_SEND_HIGH: begin
				data_to_com <= data_to_com_cache;
				uart_TxD_start <= 1;
				state_after_uart_sent <= READ_SEND_LOW;
				state <= WAITING_UART_SEND;
			end
			READ_SEND_LOW: begin
				if (start_addr == end_addr) begin
					uart_TxD_start <= 1;
					data_to_com <= checksum;
					state_after_uart_sent <= IDLE;
					state <= WAITING_UART_SEND;
				end else
					state <= READ_READ_FLASH;
			end

			WAITING_UART_SEND:
				if (uart_TxD_busy) begin
					state <= WAITING_UART_SEND_1;
					uart_TxD_start <= 0;
				end
			WAITING_UART_SEND_1: begin
				if (~uart_TxD_busy)
					state <= state_after_uart_sent;
			end

			ERROR:
				state <= ERROR;	// loop forever

			default:
				state <= IDLE;
		endcase
	end

endmodule

