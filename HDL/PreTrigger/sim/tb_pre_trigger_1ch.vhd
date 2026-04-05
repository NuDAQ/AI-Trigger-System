-- =============================================================================
--  tb_pre_trigger_1ch.vhd
--  Testbench for PRE_TRIGGER_1CH (single-channel Hi-Lo bipolar gate)
--
--  Parameters under test
--    THRESH      = 100  (x"064")  -- ±100 ADC counts
--    HILO_WINDOW =   5  ("00101") -- gate open for 5 samples after crossing
--
--  Test cases
--    T01  Hi-only crossing              → GATE all 0
--    T02  Lo-only crossing              → GATE all 0
--    T03  Hi@0 then Lo@3  (gap 3 < W)  → GATE(3,4)=1
--    T04  Hi@0 then Lo@5  (gap 5 = W)  → GATE all 0   (boundary, NOT <)
--    T05  Lo@0 then Hi@3  (reversed)   → GATE(3,4)=1
--    T06  Hi@10 then Lo@12 (mid-batch) → GATE(12,13,14)=1
--    T07  Cross-batch carry
--           Batch-A : Hi@30, Lo@31     → GATE_A(31)=1
--                                         carry_hi=3, carry_lo=4
--           Batch-B : all-zero         → GATE_B(0,1,2)=1  (carry opens 3 bins)
--    T08  RESET clears carry state
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pre_trigger_pkg.all;

entity tb_pre_trigger_1ch is
end entity;

architecture sim of tb_pre_trigger_1ch is

    -- -------------------------------------------------------------------------
    --  DUT interface
    -- -------------------------------------------------------------------------
    signal CLK         : std_logic := '0';
    signal RESET       : std_logic := '1';
    signal DATA_STR    : std_logic := '0';
    signal ADC_DATA    : adc_data_type := (others => (others => '0'));
    signal THRESH      : std_logic_vector(11 downto 0);
    signal HILO_WINDOW : std_logic_vector( 4 downto 0);
    signal GATE        : std_logic_vector(0 to 31);

    -- -------------------------------------------------------------------------
    --  Testbench constants
    -- -------------------------------------------------------------------------
    constant CLK_PERIOD : time    := 10 ns;
    constant ADC_HI     : std_logic_vector(11 downto 0) :=
                              std_logic_vector(to_signed( 150, 12));  -- +150
    constant ADC_LO     : std_logic_vector(11 downto 0) :=
                              std_logic_vector(to_signed(-150, 12));  -- -150
    constant ADC_ZERO   : std_logic_vector(11 downto 0) := (others => '0');

begin

    -- -------------------------------------------------------------------------
    --  DUT
    -- -------------------------------------------------------------------------
    U_DUT : entity work.PRE_TRIGGER_1CH
        generic map (CH => 0)
        port map (
            CLK         => CLK,
            RESET       => RESET,
            DATA_STR    => DATA_STR,
            ADC_DATA    => ADC_DATA,
            THRESH      => THRESH,
            HILO_WINDOW => HILO_WINDOW,
            GATE        => GATE
        );

    -- -------------------------------------------------------------------------
    --  Clock
    -- -------------------------------------------------------------------------
    CLK <= not CLK after CLK_PERIOD / 2;

    -- -------------------------------------------------------------------------
    --  Stimulus
    -- -------------------------------------------------------------------------
    THRESH      <= x"064";  -- 100
    HILO_WINDOW <= "00101"; -- 5 samples

    stimulus : process
        variable b   : adc_data_type;
        variable exp : std_logic_vector(0 to 31);

        -- Apply one DATA_STR pulse; GATE is valid after the rising edge.
        -- Caller reads GATE after this procedure returns.
        procedure send_batch (constant batch : in adc_data_type) is
        begin
            ADC_DATA <= batch;
            DATA_STR <= '1';
            wait until rising_edge(CLK);
            DATA_STR <= '0';
            wait for 1 ns;   -- advance past delta cycles to see registered GATE
        end procedure;

    begin
        -- -----------------------------------------------------------------------
        --  Reset
        -- -----------------------------------------------------------------------
        RESET <= '1';
        wait until rising_edge(CLK);
        wait until rising_edge(CLK);
        RESET <= '0';
        wait until rising_edge(CLK);

        -- -----------------------------------------------------------------------
        --  T01 : Hi-only crossing  →  GATE must be all zeros
        -- -----------------------------------------------------------------------
        b := (others => ADC_ZERO);
        b(5) := ADC_HI;
        send_batch(b);
        assert GATE = (0 to 31 => '0')
            report "T01 FAIL: Hi-only should not trigger GATE" severity failure;
        report "T01 PASS  Hi-only does not fire GATE";

        -- -----------------------------------------------------------------------
        --  T02 : Lo-only crossing  →  GATE must be all zeros
        -- -----------------------------------------------------------------------
        b := (others => ADC_ZERO);
        b(5) := ADC_LO;
        send_batch(b);
        assert GATE = (0 to 31 => '0')
            report "T02 FAIL: Lo-only should not trigger GATE" severity failure;
        report "T02 PASS  Lo-only does not fire GATE";

        -- -----------------------------------------------------------------------
        --  T03 : Hi@0, Lo@3, W=5  →  GATE(3)=1, GATE(4)=1, rest 0
        --
        --  gate_hi open at i=0..4  (ot_hi(0), distance 0..4 < 5)
        --  gate_lo open at i=3..7  (ot_lo(3), distance 0..4 < 5)
        --  GATE = AND  →  i=3,4
        -- -----------------------------------------------------------------------
        b := (others => ADC_ZERO);
        b(0) := ADC_HI;
        b(3) := ADC_LO;
        send_batch(b);
        exp    := (others => '0');
        exp(3) := '1';
        exp(4) := '1';
        assert GATE = exp
            report "T03 FAIL: Hi@0 Lo@3 expected GATE(3,4)=1" severity failure;
        report "T03 PASS  Hi@0 Lo@3  GATE(3,4)=1";

        -- -----------------------------------------------------------------------
        --  T04 : Hi@0, Lo@5, W=5  →  gap = W (not < W)  →  GATE all zeros
        --
        --  gate_hi open at i=0..4
        --  gate_lo open at i=5..9
        --  No overlap → GATE all 0
        -- -----------------------------------------------------------------------
        b := (others => ADC_ZERO);
        b(0) := ADC_HI;
        b(5) := ADC_LO;
        send_batch(b);
        assert GATE = (0 to 31 => '0')
            report "T04 FAIL: gap=W should not trigger (boundary check)" severity failure;
        report "T04 PASS  Hi@0 Lo@5 (gap=W) does not fire GATE";

        -- -----------------------------------------------------------------------
        --  T05 : Lo@0, Hi@3, W=5  (reversed polarity order)
        --        Expected same overlap as T03: GATE(3,4)=1
        --
        --  gate_lo open at i=0..4  (ot_lo(0))
        --  gate_hi open at i=3..7  (ot_hi(3))
        --  GATE = AND  →  i=3,4
        -- -----------------------------------------------------------------------
        b := (others => ADC_ZERO);
        b(0) := ADC_LO;
        b(3) := ADC_HI;
        send_batch(b);
        exp    := (others => '0');
        exp(3) := '1';
        exp(4) := '1';
        assert GATE = exp
            report "T05 FAIL: Lo@0 Hi@3 (reversed) expected GATE(3,4)=1" severity failure;
        report "T05 PASS  Lo@0 Hi@3 (reversed order) GATE(3,4)=1";

        -- -----------------------------------------------------------------------
        --  T06 : Hi@10, Lo@12, W=5  (mid-batch pulse)
        --        gate_hi open at i=10..14
        --        gate_lo open at i=12..16
        --        GATE = AND  →  i=12,13,14
        -- -----------------------------------------------------------------------
        b := (others => ADC_ZERO);
        b(10) := ADC_HI;
        b(12) := ADC_LO;
        send_batch(b);
        exp     := (others => '0');
        exp(12) := '1';
        exp(13) := '1';
        exp(14) := '1';
        assert GATE = exp
            report "T06 FAIL: Hi@10 Lo@12 expected GATE(12..14)=1" severity failure;
        report "T06 PASS  Hi@10 Lo@12  GATE(12,13,14)=1";

        -- -----------------------------------------------------------------------
        --  T07 : Cross-batch carry
        --
        --  Batch-A: Hi@30, Lo@31
        --    gate_hi open at i=30,31  (ot_hi(30), distance ≤ 4 for i=30,31)
        --    gate_lo open at i=31     (ot_lo(31), distance 0 < 5)
        --    GATE_A(31)=1
        --    carry_hi = 30+5-32 = 3   (gate extends 3 samples into next batch)
        --    carry_lo = 31+5-32 = 4
        --
        --  Batch-B: all-zero
        --    gate_hi: i<3 from carry   → i=0,1,2
        --    gate_lo: i<4 from carry   → i=0,1,2,3
        --    GATE_B = AND  →  i=0,1,2
        -- -----------------------------------------------------------------------
        b := (others => ADC_ZERO);
        b(30) := ADC_HI;
        b(31) := ADC_LO;
        send_batch(b);
        exp     := (others => '0');
        exp(31) := '1';
        assert GATE = exp
            report "T07 FAIL Batch-A: expected only GATE(31)=1" severity failure;
        report "T07a PASS  Batch-A: GATE(31)=1, carry_hi=3 carry_lo=4";

        -- Batch-B: all zeros, exercises the carry path
        b := (others => ADC_ZERO);
        send_batch(b);
        exp    := (others => '0');
        exp(0) := '1';
        exp(1) := '1';
        exp(2) := '1';
        assert GATE = exp
            report "T07 FAIL Batch-B: expected GATE(0,1,2)=1 from carry" severity failure;
        report "T07b PASS  Batch-B: GATE(0,1,2)=1 from cross-batch carry";

        -- -----------------------------------------------------------------------
        --  T08 : RESET clears carry  →  after reset, empty batch gives GATE=0
        -- -----------------------------------------------------------------------
        -- First build up carry state (same as batch-A of T07)
        b := (others => ADC_ZERO);
        b(30) := ADC_HI;
        b(31) := ADC_LO;
        send_batch(b);
        -- Now reset
        RESET <= '1';
        wait until rising_edge(CLK);
        RESET <= '0';
        wait until rising_edge(CLK);
        -- Apply empty batch — carry should be gone
        b := (others => ADC_ZERO);
        send_batch(b);
        assert GATE = (0 to 31 => '0')
            report "T08 FAIL: RESET should clear carry; GATE must be all 0" severity failure;
        report "T08 PASS  RESET clears carry state";

        -- -----------------------------------------------------------------------
        report "========================================";
        report "ALL PRE_TRIGGER_1CH TESTS PASSED";
        report "========================================";
        std.env.finish;
    end process;

end architecture;
