/*
 * NanoTrade Order Book Engine  (v3 — ML Circuit Breaker)
 * ========================================================
 * Adds ML-driven adaptive circuit breaker:
 *
 *  cb_mode[1:0]  Action
 *  ----------    -------
 *  2'b00         NORMAL   — full-speed matching (no restriction)
 *  2'b01         THROTTLE — accept 1 order every (cb_param>>4 + 1) cycles
 *                           Used for QUOTE_STUFFING detection.
 *  2'b10         WIDEN    — matching continues but crossing threshold raised
 *                           by spread_guard ticks so only deeply crossed books
 *                           execute. Used for ORDER_IMBALANCE.
 *  2'b11         PAUSE    — matching frozen for 2×cb_param cycles, then
 *                           auto-resumes in NORMAL.
 *                           Used for FLASH_CRASH.
 *
 * cb_param[7:0]  ML confidence (0..255) scaled per mode:
 *   PAUSE    : countdown = 2 × cb_param  (max 510 cycles = 10.2 µs @ 50 MHz)
 *   THROTTLE : accept 1 order every (cb_param>>4)+1 cycles
 *   WIDEN    : spread guard ticks = cb_param>>5  (0..7)
 *
 * Circuit breaker self-heals: countdown expires → back to NORMAL with no
 * host intervention needed.  Minimum response latency = 1 cycle after
 * ML valid pulse (≈ 20 ns @ 50 MHz).
 */

`default_nettype none



module order_book (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [1:0] input_type,

    /* verilator lint_off UNUSEDSIGNAL */
    input  wire [5:0] data_in,

    input  wire [5:0] ext_data, /* verilator lint_on UNUSEDSIGNAL */
    // ── ML Circuit Breaker Interface ────────────────────────────────
    input  wire [1:0] cb_mode,       // 00=normal 01=throttle 10=widen 11=pause
    input  wire [7:0] cb_param,      // confidence-derived parameter
    input  wire       cb_load,       // 1-cycle pulse to latch new CB config
    // ── Outputs ─────────────────────────────────────────────────────
    output reg        match_valid,
    output reg  [7:0] match_price,
    output wire       cb_active,     // 1 = CB currently engaged
    output wire [1:0] cb_state       // current CB mode
);

    // ----------------------------------------------------------------
    // Order book: 4 bids, 4 asks  [{valid, price[6:0]}]
    // ----------------------------------------------------------------
    reg [7:0] bid [0:3];
    reg [7:0] ask [0:3];

    wire [6:0] new_price = {1'b0, ext_data[0], data_in[5:1]};
    wire       is_buy    = (input_type == 2'b10);
    wire       is_sell   = (input_type == 2'b11);

    // ----------------------------------------------------------------
    // Best bid / ask (comb)
    // ----------------------------------------------------------------
    reg [6:0] best_bid; reg best_bid_valid; reg [1:0] best_bid_idx;
    reg [6:0] best_ask; reg best_ask_valid; reg [1:0] best_ask_idx;
    integer i3;

    always @(*) begin : best_finder
        reg [2:0] i;
        best_bid=7'h00; best_bid_valid=1'b0; best_bid_idx=2'd0;
        best_ask=7'h7F; best_ask_valid=1'b0; best_ask_idx=2'd0;
        for(i=3'd0;i<3'd4;i=i+3'd1) begin
            if(bid[i][7]&&(!best_bid_valid||bid[i][6:0]>best_bid)) begin
                best_bid=bid[i][6:0]; best_bid_valid=1'b1; best_bid_idx=i[1:0]; end
        end
        for(i=3'd0;i<3'd4;i=i+3'd1) begin
            if(ask[i][7]&&(!best_ask_valid||ask[i][6:0]<best_ask)) begin
                best_ask=ask[i][6:0]; best_ask_valid=1'b1; best_ask_idx=i[1:0]; end
        end
    end

    // ----------------------------------------------------------------
    // Empty slot finder (comb)
    // ----------------------------------------------------------------
    reg [1:0] empty_bid_slot; reg has_empty_bid;
    reg [1:0] empty_ask_slot; reg has_empty_ask;

    always @(*) begin : slot_finder
        // Unrolled (was: for i2=3 downto 0) — avoids integer-in-comb-block Yosys issue
        empty_bid_slot=2'd0; has_empty_bid=1'b0;
        empty_ask_slot=2'd0; has_empty_ask=1'b0;
        if(!bid[3][7]) begin empty_bid_slot=2'd3; has_empty_bid=1'b1; end
        if(!ask[3][7]) begin empty_ask_slot=2'd3; has_empty_ask=1'b1; end
        if(!bid[2][7]) begin empty_bid_slot=2'd2; has_empty_bid=1'b1; end
        if(!ask[2][7]) begin empty_ask_slot=2'd2; has_empty_ask=1'b1; end
        if(!bid[1][7]) begin empty_bid_slot=2'd1; has_empty_bid=1'b1; end
        if(!ask[1][7]) begin empty_ask_slot=2'd1; has_empty_ask=1'b1; end
        if(!bid[0][7]) begin empty_bid_slot=2'd0; has_empty_bid=1'b1; end
        if(!ask[0][7]) begin empty_ask_slot=2'd0; has_empty_ask=1'b1; end
    end

    // ================================================================
    // CIRCUIT BREAKER STATE MACHINE
    // ================================================================

    reg [1:0]  cb_mode_r;
    reg [8:0]  cb_countdown;      // 9-bit: up to 510 cycles
/* verilator lint_off UNUSEDSIGNAL */ reg [7:0]  cb_param_r; /* verilator lint_on UNUSEDSIGNAL */
       reg [3:0]  throttle_cnt;

    wire [3:0] throttle_div   = cb_param_r[7:4];
    wire       throttle_allow = (throttle_cnt == 4'd0);
    wire [2:0] spread_guard   = cb_param_r[7:5];

    assign cb_active = (cb_mode_r != 2'b00);
    assign cb_state  = cb_mode_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cb_mode_r    <= 2'b00;
            cb_countdown <= 9'd0;
            cb_param_r   <= 8'd0;
            throttle_cnt <= 4'd0;
        end else begin
            if (cb_load) begin
                // Latch new CB config from ML engine
                cb_mode_r  <= cb_mode;
                cb_param_r <= cb_param;
                case (cb_mode)
                    2'b00: cb_countdown <= 9'd0;
                    2'b01: cb_countdown <= {1'b0, cb_param};
                    2'b10: cb_countdown <= {1'b0, cb_param};
                    2'b11: cb_countdown <= {cb_param[7:0], 1'b0}; // 2× for PAUSE
                endcase
                throttle_cnt <= 4'd0;
            end else begin
                // Countdown expiry → self-heal to NORMAL
                if (cb_mode_r != 2'b00) begin
                    if (cb_countdown == 9'd0)
                        cb_mode_r <= 2'b00;
                    else
                        cb_countdown <= cb_countdown - 9'd1;
                end

                // Throttle divider counter
                if (cb_mode_r == 2'b01) begin
                    if (throttle_cnt == throttle_div)
                        throttle_cnt <= 4'd0;
                    else
                        throttle_cnt <= throttle_cnt + 4'd1;
                end else
                    throttle_cnt <= 4'd0;
            end
        end
    end

    // ================================================================
    // ORDER INSERTION + MATCHING  (CB-enforced)
    // ================================================================

    wire order_gate = (cb_mode_r == 2'b11) ? 1'b0 :          // PAUSE: block
                      (cb_mode_r == 2'b01) ? throttle_allow : // THROTTLE: gate
                      1'b1;                                     // NORMAL/WIDEN: free

    wire match_gate = (cb_mode_r == 2'b11) ? 1'b0 :  // PAUSE: no matches
                      1'b1;

    // Spread guard: widen effective crossing threshold in WIDEN mode
    // Spread guard only active in WIDEN mode (cb_mode_r == 2'b10)
    wire [2:0] active_guard    = (cb_mode_r == 2'b10) ? spread_guard : 3'd0;
    wire [6:0] cross_threshold = best_ask + {4'd0, active_guard};
    wire       crossing = best_bid_valid && best_ask_valid &&
                          (best_bid >= cross_threshold);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            match_valid <= 1'b0;
            match_price <= 8'd0;
            for(i3=0;i3<4;i3=i3+1) begin bid[i3]<=8'h00; ask[i3]<=8'h00; end
        end else begin
            match_valid <= 1'b0;

            // Insert (CB gated)
            if (order_gate) begin
                if (is_buy  && has_empty_bid) bid[empty_bid_slot] <= {1'b1, new_price};
                if (is_sell && has_empty_ask) ask[empty_ask_slot] <= {1'b1, new_price};
            end

            // Match (CB gated + spread guard)
            if (match_gate && crossing) begin
                match_valid             <= 1'b1;
                match_price             <= {1'b0, best_ask};
                bid[best_bid_idx]       <= 8'h00;
                ask[best_ask_idx]       <= 8'h00;
            end
        end
    end

endmodule
// end
