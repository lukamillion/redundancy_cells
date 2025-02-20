// Copyright 2021 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
// 
// Scrubber for ecc

module ecc_scrubber #(
  parameter  int unsigned BankSize       = 256,
  parameter  bit          UseExternalECC = 0,
  localparam int unsigned DataWidth      = 39
) (
  input  logic                        clk_i,
  input  logic                        rst_ni,

  input  logic                        scrub_trigger_i,
  output logic [                31:0] bit_corrections_o,

  // Input signals from others accessing memory bank
  input  logic                        intc_req_i,
  input  logic                        intc_we_i,
  input  logic [$clog2(BankSize)-1:0] intc_add_i,
  input  logic [       DataWidth-1:0] intc_wdata_i,
  output logic [       DataWidth-1:0] intc_rdata_o,

  // Output directly to bank
  output logic                        bank_req_o,
  output logic                        bank_we_o,
  output logic [$clog2(BankSize)-1:0] bank_add_o,
  output logic [       DataWidth-1:0] bank_wdata_o,
  input  logic [       DataWidth-1:0] bank_rdata_i,

  // If using external ECC
  output logic [       DataWidth-1:0] ecc_out_o,
  input  logic [       DataWidth-1:0] ecc_in_i,
  input  logic [                 2:0] ecc_err_i
);

  logic [                 1:0] ecc_err;
  logic [                31:0] data_tmp;

  logic                        scrub_req;
  logic                        scrub_we;
  logic [$clog2(BankSize)-1:0] scrub_add;
  logic [       DataWidth-1:0] scrub_wdata;
  logic [       DataWidth-1:0] scrub_rdata;

  typedef enum logic [2:0] {Idle, Read, Write} scrub_state_e;

  scrub_state_e state_d, state_q;

  logic [$clog2(BankSize)-1:0] working_add_d, working_add_q;
  assign scrub_add = working_add_q;

  always_comb begin : proc_bank_assign
    bank_req_o   = intc_req_i || scrub_req;
    intc_rdata_o = bank_rdata_i;
    scrub_rdata  = bank_rdata_i;

    bank_we_o    = intc_we_i;
    bank_add_o   = intc_add_i;
    bank_wdata_o = intc_wdata_i;
    
    if ( (state_q == Read || state_q == Write) && intc_req_i == 1'b0) begin
      bank_we_o    = scrub_we;
      bank_add_o   = scrub_add;
      bank_wdata_o = scrub_wdata;
    end
  end

  if (UseExternalECC) begin
    assign ecc_err = ecc_err_i;
    assign ecc_out_o = scrub_rdata;
    assign scrub_wdata = ecc_in_i;
  end else begin
    assign ecc_out_o = '0;
    prim_secded_39_32_dec ecc_decode (
      .in        (scrub_rdata),
      .d_o       (data_tmp),
      .syndrome_o(),
      .err_o     (ecc_err)
    );
    prim_secded_39_32_enc ecc_encode (
      .in (data_tmp),
      .out(scrub_wdata)
    );
  end

  always_comb begin : proc_FSM_logic
    state_d       = state_q;
    scrub_req     = 1'b0;
    scrub_we      = 1'b0;
    working_add_d = working_add_q;

    if (state_q == Idle) begin
      if (scrub_trigger_i) begin
        state_d = Read;
      end
    end else if (state_q == Read) begin
      scrub_req = 1'b1;
      if (intc_req_i == 1'b0) begin
        state_d = Write;
      end
    end else if (state_q == Write) begin
      if (ecc_err[0] == 1'b0) begin   // No Error (maybe not correctable)
        state_d       = Idle;
        working_add_d = (working_add_q + 1) % BankSize;
      end else begin                  // Correctable Error
        scrub_req = 1'b1;
        scrub_we  = 1'b1;
        if (intc_req_i == 1'b1) begin // INTC interference - retry read and write
          state_d = Read;
        end else begin                // Error corrected
          state_d       = Idle;
          working_add_d = (working_add_q + 1) % BankSize;
        end
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : proc_bank_add
    if(~rst_ni) begin
      working_add_q <= '0;
    end else begin
      working_add_q <= working_add_d;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : proc_FSM
    if(~rst_ni) begin
      state_q <= Idle;
    end else begin
      state_q <= state_d;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : proc_bit_corrections
    if(~rst_ni) begin
      bit_corrections_o <= 0;
    end else begin
      if (ecc_err[0] == 1) begin
        bit_corrections_o <= bit_corrections_o + 1;
      end else begin
        bit_corrections_o <= bit_corrections_o;
      end
    end
  end

endmodule
