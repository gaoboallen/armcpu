/*
 * $File: vga_driver.v
 * $Date: Sat Nov 02 19:51:54 2013 +0800
 * $Author: Xinyu Zhou <zxytim@gmail.com>
 *          jiakai <jia.kai66@gmail.com>
 */


// specification reference:
// http://tinyvga.com/vga-timing/640x480@60Hz
module vga_driver(
	input clk50M,
//    input [20:0] ram_start_addr, // display data is from ram_start_addr

	output reg [8:0] color_out, // 3 red, 3 green, 3 blue
	output hsync,
	output vsync
	);


	localparam H_VISIBLE_AREA = 640,
		H_FRONT_PORCH = 16,
		H_SYNC_PULSE = 96,
		H_BACK_PORCH = 48,
		H_WHOLE = 800;

	localparam V_VISIBLE_AREA = 480,
		V_FRONT_PORCH = 10,
		V_SYNC_PULSE = 2,
		V_BACK_PORCH = 33,
		V_WHOLE = 525;

	reg clk25M = 0;
	always @(posedge clk50M) begin
		clk25M <= clk25M ^ 1'b1;
	end
	assign clk = clk50M;

	reg [9:0] hsync_cnt = 0;
	reg [9:0] vsync_cnt = 0;

	assign hsync = (hsync_cnt >= H_SYNC_PULSE);
	assign vsync = (vsync_cnt >= V_SYNC_PULSE);

	wire [9:0] pixel_x = (hsync_cnt >= H_SYNC_PULSE + H_FRONT_PORCH ?
		hsync_cnt - H_SYNC_PULSE - H_FRONT_PORCH : {10{1'b1}});
	wire [9:0] pixel_y = (vsync_cnt >= V_SYNC_PULSE + V_FRONT_PORCH ?
		vsync_cnt - V_SYNC_PULSE - V_FRONT_PORCH : {10{1'b1}});

	wire should_draw = pixel_x >= 0 && pixel_x < H_VISIBLE_AREA && pixel_y >= 0 && pixel_y < V_VISIBLE_AREA;

	always @(posedge clk)
		if (clk25M) begin
			if (hsync_cnt == H_WHOLE - 1) begin
				hsync_cnt <= 0;
				if (vsync_cnt == V_WHOLE - 1) begin
					vsync_cnt <= 0;
				end else begin
					vsync_cnt <= vsync_cnt + 1'b1;
				end
			end else begin
				hsync_cnt <= hsync_cnt + 1'b1;
			end
			if (should_draw)
				if (pixel_x < 320)
					color_out <= 9'b101010101;
				else
					color_out <= 9'b000000111;
			else
				color_out <= 0;
		end

endmodule
