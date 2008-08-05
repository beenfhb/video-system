-------------------------------------------------------------------------
-- H264 top level (skeleton) - VHDL
-- 
-- Written by Andy Henson
-- Copyright (c) 2008 Zexia Access Ltd
-- All rights reserved.
--
-- Redistribution and use in source and binary forms, with or without
-- modification, are permitted provided that the following conditions are met:
--    * Redistributions of source code must retain the above copyright
--      notice, this list of conditions and the following disclaimer.
--    * Redistributions in binary form must reproduce the above copyright
--      notice, this list of conditions and the following disclaimer in the
--      documentation and/or other materials provided with the distribution.
--    * Neither the name of the Zexia Access Ltd nor the
--      names of its contributors may be used to endorse or promote products
--      derived from this software without specific prior written permission.
--
-- THIS SOFTWARE IS PROVIDED BY ZEXIA ACCESS LTD ``AS IS'' AND ANY
-- EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
-- WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
-- DISCLAIMED. IN NO EVENT SHALL ZEXIA ACCESS LTD OR ANDY HENSON BE LIABLE FOR ANY
-- DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
-- (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
-- LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
-- ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
-- (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
-- SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
-------------------------------------------------------------------------

-- This is an example top level module for the H264 submodules.
-- Each implementation will differ at the top level due to differing
-- number of video streams, resolution, and RAM type and interface.
-- This is thus just a skeleton implementation.

-- Generic design: (please see pdf file with nice block diagram)
-- There are two almost independant dataflows here, the predict/quantise
-- loop with dequantise reconstruct feedback to next prediction runs at
-- the front, outputing to xbuffer and header modules.
-- Once a macroblock has completed in the predict/quantise loop, the cavlc
-- backend takes the data: the header module outputs the header and
-- the xbuffer module pumps stuff through cavlc module and both end up
-- via tobytes.  This proceeds as the next macroblock is being processed
-- in predict/quantise.
-- at the end of a line, we wait for DONE asserted by xbuffer to say
-- all quiescent (neither front end not back end busy; although there
-- is still data being clocked out via cavlc for another 20 clocks or so
-- and tobytes for another up to 100 clocks depending on size of fifo.

-- All this is regulated by a number of READY lines which pause earlier stages
-- if needed.  tobytes and cavlc pause the xbuffer pump (but not until the end
-- of the current submb - up to 16 clks).  xbuffer can pause prediction.  And
-- the prediction controls the feed of data in from image buffers.  To overcome
-- the "floppiness" of the feedback (up to 40 clks), there is a
-- fifo in tobytes as well as the ram in xbuffer module.

-- QP: note there is only a single QPvalue used here, really there should be
-- a separate one for chroma for QP>=30 or chroma_qp_index_offset/=0 (in PP).
-- latch either QPy or QPc on entry to coretransform, latch on entry to quantise
-- and dequantise when enable low.  That'll work.

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;
use ieee.numeric_std.ALL;
USE std.textio.all;
use work.h264.all;
use work.misc.all;

--pre-headers (suggested)
--SPS: 00 00 00 01 ; 67 42 00 28 da 05 82 59 	-- contains size of image 352x288
--PPS: 00 00 00 01 ; 68 ce 38 80				-- default zero params
--Slice: 00 00 00 01 (rest of slice is generated by h264header).

entity h264topskeleton is
	generic (
		IMGWIDTH : integer := 352;	--sample stuff is 352x288
		IMGHEIGHT : integer := 288;
		IWBITS : integer := 9
	);
	port (
		signal CLK : in std_logic;			--clock
		signal CLK2 : in std_logic;			--2x clock
		--
		-- controls
		signal NEWSLICE : in std_logic;			--reset: this is the first a slice
		signal NEWLINE : in std_logic;			--newline: first mb and submb
		signal QP : in std_logic_vector(5 downto 0);
		signal xbuffer_DONE : out std_logic := '0';
		--
		-- inputs (from buffer)
		signal intra4x4_READYI : out std_logic := '0';				--ready for enable when this set
		signal intra4x4_STROBEI : in std_logic := '0';				--values transfered only when this is 1
		signal intra4x4_DATAI : in std_logic_vector(31 downto 0) := (others => '0');
		signal intra8x8cc_readyi : out std_logic := '0';				--ready for enable when this set
		signal intra8x8cc_strobei : in std_logic := '0';				--values transfered only when this is 1
		signal intra8x8cc_datai : in std_logic_vector(31 downto 0) := (others => '0');
		--
		-- outputs
		signal tobytes_BYTE : out std_logic_vector(7 downto 0) := (others=>'0');
		signal tobytes_STROBE : out std_logic := '0';	-- BYTE valid
		signal tobytes_DONE : out std_logic := '0'		-- NAL all done
	);
end h264topskeleton;

architecture hw of h264topskeleton is
	signal intra4x4_TOPI : std_logic_vector(31 downto 0) := (others => '0');
	signal intra4x4_TOPMI : std_logic_vector(3 downto 0) := (others => '0');
	signal intra4x4_STROBEO : std_logic := '0';				--values transfered out when this is 1
	signal intra4x4_READYO : std_logic := '0';				--when ready for out
	signal intra4x4_DATAO : std_logic_vector(35 downto 0) := (others => '0');
	signal intra4x4_BASEO : std_logic_vector(31 downto 0) := (others => '0');
	signal intra4x4_MSTROBEO : std_logic := '0';			--mode transfered only when this is 1	
	signal intra4x4_MODEO : std_logic_vector(3 downto 0) := (others => '0');	--0..8 prediction type
	signal intra4x4_PMODEO : std_logic := '0';	--prediction type same
	signal intra4x4_RMODEO : std_logic_vector(2 downto 0) := (others => '0');	--prediction type rem
	signal intra4x4_XXO : std_logic_vector(1 downto 0) := (others => '0');
	signal intra4x4_XXINC : std_logic := '0';
	signal intra4x4_CHREADY : std_logic := '0';
	--
	signal intra8x8cc_TOPI : std_logic_vector(31 downto 0) := (others => '0');
	signal intra8x8cc_STROBEO : std_logic := '0';				--values transfered out when this is 1
	signal intra8x8cc_READYO : std_logic := '0';				--when ready for out
	signal intra8x8cc_DATAO : std_logic_vector(35 downto 0) := (others => '0');
	signal intra8x8cc_BASEO : std_logic_vector(31 downto 0) := (others => '0');
	signal intra8x8cc_dcstrobeo : std_logic := '0';				--when ready for out
	signal intra8x8cc_dcdatao : std_logic_vector(15 downto 0) := (others => '0');
	signal intra8x8cc_CMODEO : std_logic_vector(1 downto 0) := (others => '0');	--0..8 prediction type
	signal intra8x8cc_XXO : std_logic_vector(1 downto 0) := (others => '0');
	signal intra8x8cc_XXC : std_logic := '0';
	signal intra8x8cc_XXINC : std_logic := '0';
	--
	signal header_CMODE : std_logic_vector(1 downto 0) := b"00";	--intra_chroma_pred_mode
	signal header_VE : std_logic_vector(19 downto 0) := (others=>'0');
	signal header_VL : std_logic_vector(4 downto 0) := (others=>'0');
	signal header_VALID : std_logic := '0';	-- VE/VL valid
	--
	signal coretransform_READY : std_logic := '0';				--ready for enable when this set
	signal coretransform_ENABLE : std_logic := '0';				--values transfered only when this is 1
	signal coretransform_XXIN : std_logic_vector(35 downto 0) := (others => '0');
	signal coretransform_valid : std_logic := '0';
	signal coretransform_ynout : std_logic_vector(13 downto 0);
	--
	signal dctransform_VALID : std_logic := '0';
	signal dctransform_yyout : std_logic_vector(15 downto 0);
	signal dctransform_readyo : std_logic := '0';
	--
	signal quantise_ENABLE : std_logic := '0';
	signal quantise_YNIN : std_logic_vector(15 downto 0);
	signal quantise_valid : std_logic := '0';
	signal quantise_zout : std_logic_vector(11 downto 0);
	signal quantise_dcco : std_logic := '0';
	--
	signal dequantise_enable : std_logic := '0';
	signal dequantise_zin : std_logic_vector(11 downto 0);
	signal dequantise_last : std_logic := '0';
	signal dequantise_valid : std_logic := '0';
	signal dequantise_dcco : std_logic := '0';
	signal dequantise_wout : std_logic_vector(15 downto 0);
	--
	signal invdctransform_enable : std_logic := '0';
	signal invdctransform_zin : std_logic_vector(15 downto 0);
	signal invdctransform_valid : std_logic := '0';
	signal invdctransform_yyout : std_logic_vector(15 downto 0);
	signal invdctransform_ready : std_logic := '0';
	--
	--signal invtransform_enable : std_logic := '0';
	--signal invtransform_win : std_logic_vector(15 downto 0);
	--signal invtransform_last : std_logic := '0';
	signal invtransform_valid : std_logic := '0';
	signal invtransform_xout : std_logic_vector(35 downto 0);
	--
	signal recon_BSTROBEI : std_logic := '0';				--values transfered only when this is 1
	signal recon_basei : std_logic_vector(31 downto 0) := (others => '0');
	signal recon_FBSTROBE : std_logic := '0';				--feedback transfered only when this is 1
	signal recon_FBCSTROBE : std_logic := '0';				--feedback transfered only when this is 1
	signal recon_FEEDB : std_logic_vector(31 downto 0) := (others => '0');
	--
	signal xbuffer_NLOAD : std_logic := '0';		--load for CAVLC NOUT
	signal xbuffer_NX : std_logic_vector(2 downto 0);	--X value for NIN/NOUT
	signal xbuffer_NY : std_logic_vector(2 downto 0);	--Y value for NIN/NOUT
	signal xbuffer_NV : std_logic_vector(1 downto 0);	--valid flags for NIN/NOUT (1=left, 2=top, 3=avg)
	signal xbuffer_NXINC : std_logic := '0';		--increment for X macroblock counter
	signal xbuffer_READYI : std_logic := '0';
	--signal xbuffer_DCREADYI : std_logic := '0';
	signal xbuffer_CCIN : std_logic := '0';
	--
	signal cavlc_ENABLE : std_logic := '0';				--values transfered only when this is 1
	signal cavlc_READY : std_logic;				--values transfered only when this is 1
	signal cavlc_VIN : std_logic_vector(11 downto 0) := x"000";		--12bits max (+/- 2048)
	signal cavlc_NIN : std_logic_vector(4 downto 0) :=b"00000";	--N coeffs nearby mb
	signal cavlc_VE : std_logic_vector(24 downto 0) := (others=>'0');
	signal cavlc_VL : std_logic_vector(4 downto 0) := (others=>'0');
	signal cavlc_VALID : std_logic := '0';	-- enable delayed to same as VE/VL
	signal cavlc_XSTATE : std_logic_vector(2 downto 0) := (others=>'0');
	signal cavlc_NOUT : std_logic_vector(4 downto 0);
	--
	signal tobytes_READY : std_logic;					--soft "ready" flag
	signal tobytes_VE : std_logic_vector(24 downto 0) := (others=>'0');
	signal tobytes_VL : std_logic_vector(4 downto 0) := (others=>'0');
	signal tobytes_VALID : std_logic := '0';	-- VE/VL1 valid
	--
	signal align_VALID : std_logic := '0';
	--
	signal ninx : std_logic_vector(7 downto 0) := x"00";	--N coeffs nearby mb: left
	signal ninl : std_logic_vector(4 downto 0) := b"00000";	--N coeffs nearby mb: left
	signal nint : std_logic_vector(4 downto 0) := b"00000";	--N coeffs nearby mb: top
	signal ninsum : std_logic_vector(5 downto 0) := b"000000";	--N coeffs nearby mb
	type Tnin is array (natural range <>) of std_logic_vector(4 downto 0);
	signal ninleft : Tnin(7 downto 0) := (others=>(others=>'0'));
	signal nintop : Tnin(2047 downto 0) := (others=>(others=>'0'));	--macroblocks*8
	--
	type Tfullrow is array (natural range <>) of std_logic_vector(31 downto 0);
	type Tfullrowm is array (natural range <>) of std_logic_vector(3 downto 0);
	signal toppix : Tfullrow(IMGWIDTH-1 downto 0) := (others=>(others=>'0'));	--actually units of 4 pixels
	signal toppixcc : Tfullrow(IMGWIDTH-1 downto 0) := (others=>(others=>'0'));	--actually units of 4 pixels
	signal topmode : Tfullrowm(IMGWIDTH-1 downto 0) := (others=>x"0");
	signal mbx : std_logic_vector(IWBITS-1 downto 0) := (others=>'0');	--macroblock x counter
	signal mbxcc : std_logic_vector(IWBITS-1 downto 0) := (others=>'0'); --macroblock x counter for chroma
	--
begin
	--
	intra4x4 : h264intra4x4
	port map (
		CLK => clk2,
		--
		-- in interface:
		NEWSLICE => NEWSLICE,
		NEWLINE => NEWLINE,
		STROBEI => intra4x4_strobei,
		DATAI => intra4x4_datai,
		READYI => intra4x4_readyi,
		--
		-- top interface:
		TOPI => intra4x4_topi,
		TOPMI => intra4x4_topmi,
		XXO => intra4x4_xxo,
		XXINC => intra4x4_xxinc,
		--
		-- feedback interface:
		FEEDBI => recon_FEEDB(31 downto 24),
		FBSTROBE => recon_FBSTROBE,
		--
		-- out interface:
		STROBEO => intra4x4_strobeo,
		DATAO => intra4x4_datao,
		BASEO => intra4x4_baseo,
		READYO => intra4x4_readyo,
		MSTROBEO => intra4x4_mstrobeo,
		MODEO => intra4x4_MODEO,
		PMODEO => intra4x4_PMODEO,
		RMODEO => intra4x4_RMODEO,
		--
		CHREADY => intra4x4_CHREADY
	);
	intra4x4_readyo <= coretransform_ready and xbuffer_readyi;-- and slowready;
	intra4x4_TOPI <= toppix(conv_integer(mbx & intra4x4_XXO));
	intra4x4_TOPMI <= topmode(conv_integer(mbx & intra4x4_XXO));
	--
	intra8x8cc : h264intra8x8cc
	port map (
		CLK2 => clk2,
		--
		-- in interface:
		NEWSLICE => NEWSLICE,
		NEWLINE => NEWLINE,
		STROBEI => intra8x8cc_strobei,
		DATAI => intra8x8cc_datai,
		READYI => intra8x8cc_readyi,
		--
		-- top interface:
		TOPI  => intra8x8cc_topi,
		XXO => intra8x8cc_xxo,
		XXC => intra8x8cc_xxc,
		XXINC => intra8x8cc_xxinc,
		--
		-- feedback interface:
		FEEDBI => recon_FEEDB(31 downto 24),
		FBSTROBE => recon_FBCSTROBE,
		--
		-- out interface:
		STROBEO => intra8x8cc_strobeo,
		DATAO => intra8x8cc_datao,
		BASEO => intra8x8cc_baseo,
		READYO => intra4x4_CHREADY,
		DCSTROBEO => intra8x8cc_dcstrobeo,
		DCDATAO => intra8x8cc_dcdatao,
		CMODEO => intra8x8cc_cmodeo
	);
	intra8x8cc_TOPI <= toppixcc(conv_integer(mbxcc & intra8x8cc_XXO));
	--
	header : h264header
	port map (
		CLK => clk,
		NEWSLICE => NEWSLICE,
		--LASTSLICE => '1'
		SINTRA => '1',	--all slices are Intra in this test
		--
		MINTRA => '1',	--ditto all mbs
		LSTROBE => intra4x4_strobeo,
		CSTROBE => intra4x4_strobeo, --header_cstrobe,
		QP => qp,
		--
		PMODE => intra4x4_PMODEO,
		RMODE => intra4x4_RMODEO,
		CMODE => header_cmode,
		--
		PTYPE => b"00",
		PSUBTYPE => b"00",
		MVDX => x"000",
		MVDY => x"000",
		--
		VE => header_ve,
		VL => header_vl,
		VALID => header_valid
	);
	--
	coretransform : h264coretransform
	port map (
		CLK => clk2,
		READY => coretransform_ready,
		ENABLE => coretransform_enable,
		XXIN => coretransform_xxin,
		VALID => coretransform_valid,
		YNOUT => coretransform_ynout
	);
	coretransform_enable <= intra4x4_strobeo or intra8x8cc_strobeo;
	coretransform_xxin <= intra4x4_datao when intra4x4_strobeo='1' else intra8x8cc_datao;
	recon_bstrobei <= intra4x4_strobeo or intra8x8cc_strobeo;
	recon_basei <= intra4x4_baseo when intra4x4_strobeo='1' else intra8x8cc_baseo;
	--
	dctransform : h264dctransform
	generic map ( TOGETHER => true )
	port map (
		CLK2 => clk2,
		RESET => NEWslice,
		--READYI => 
		ENABLE => intra8x8cc_dcstrobeo,
		XXIN => intra8x8cc_dcdatao,
		VALID => dctransform_valid,
		YYOUT => dctransform_yyout,
		READYO => dctransform_readyo
	);
	dctransform_readyo <= intra4x4_CHREADY and not coretransform_valid;
	--
	quantise : h264quantise
	port map (
		CLK => clk2,
		ENABLE => quantise_ENABLE, 
		QP => qp,
		DCCI => dctransform_VALID,
		YNIN => quantise_YNIN,
		ZOUT => quantise_zout,
		DCCO => quantise_dcco,
		VALID => quantise_valid
	);
	quantise_YNIN <= sxt(coretransform_ynout,16) when coretransform_valid='1' else dctransform_yyout;
	quantise_ENABLE <= coretransform_valid or dctransform_VALID;
	--
	invdctransform : h264dctransform
	port map (
		CLK2 => clk2,
		RESET => NEWslice,
		--READYI => 
		ENABLE => invdctransform_enable,
		XXIN => invdctransform_zin,
		VALID => invdctransform_valid,
		YYOUT => invdctransform_yyout,
		READYO => invdctransform_ready
	);
	invdctransform_enable <= quantise_valid and quantise_dcco;
	invdctransform_ready <= dequantise_last and xbuffer_CCIN;
	invdctransform_zin <= sxt(quantise_zout,16);
	--
	dequantise : h264dequantise
	generic map ( LASTADVANCE => 2 )
	port map (
		CLK => clk2,
		ENABLE => dequantise_enable,
		QP => qp,
		ZIN => dequantise_zin,
		DCCI => invdctransform_valid,
		LAST => dequantise_last,
		WOUT => dequantise_wout,
		--DCCO => dequantise_dcco,
		VALID => dequantise_valid
	);
	dequantise_enable <= quantise_valid and not quantise_dcco;
	dequantise_zin <= quantise_zout when invdctransform_valid='0' else invdctransform_yyout(11 downto 0);	--WIDTH!!
	--
	invtransform : h264invtransform
	port map (
		CLK => clk2,
		ENABLE => dequantise_valid,
		WIN => dequantise_wout,
		--LAST => invtransform_last,
		VALID => invtransform_valid,
		XOUT => invtransform_xout
	);
	--invtransform_enable <= dequantise_valid and not dequantise_dcco;
	--invtransform_win <= dequantise_wout when invdctransform_valid='0' else invdctransform_yyout;
	--
	recon : h264recon
	port map (
		CLK2 => clk2,
		--
		NEWSLICE => NEWSLICE,
		STROBEI => invtransform_valid,
		DATAI => invtransform_xout,
		BSTROBEI => recon_bstrobei,
		BCHROMAI => intra8x8cc_strobeo,
		BASEI => recon_basei,
		--
		STROBEO => recon_FBSTROBE,
		CSTROBEO => recon_FBCSTROBE,
		DATAO => recon_FEEDB
	);
	--
	xbuffer : h264buffer
	port map (
		CLK => clk2,
		NEWSLICE => NEWSLICE,
		NEWLINE => NEWLINE,
		--
		VALIDI => quantise_valid,
		ZIN => quantise_zout,
		READYI => xbuffer_READYI,
		--DCREADYI => xbuffer_DCREADYI,
		CCIN => xbuffer_CCIN,
		DONE => xbuffer_DONE,
		--
		VOUT => cavlc_vin,
		VALIDO => cavlc_enable,
		--
		NLOAD => xbuffer_NLOAD,
		NX => xbuffer_NX,
		NY => xbuffer_NY,
		NV => xbuffer_NV,
		NXINC => xbuffer_NXINC,
		--
		READYO => cavlc_ready,
		TREADYO => tobytes_ready,
		HVALID => header_valid
	);
	--
	cavlc : h264cavlc
	port map (
		CLK => clk,
		CLK2 => clk2,
		ENABLE => cavlc_enable,
		READY => cavlc_ready,
		VIN => cavlc_vin,
		NIN => cavlc_nin,
		SIN => '0',
		--VS => cavlc_vs,
		VE => cavlc_ve,
		VL => cavlc_vl,
		VALID => cavlc_valid,
		XSTATE => cavlc_xstate,
		NOUT => cavlc_nout
	);
	--
	tobytes: h264tobytes
	port map (
		CLK => clk,
		VALID => tobytes_valid,
		READY => tobytes_ready,
		VE => tobytes_ve,
		VL => tobytes_vl,
		BYTE => tobytes_byte,
		STROBE => tobytes_strobe,
		DONE => tobytes_DONE
	);
	tobytes_ve <= b"00000"&header_ve when header_valid='1' else
					cavlc_ve when cavlc_valid='1' else
					'0'&x"030080";		--align+done pattern
	tobytes_vl <= header_vl when header_valid='1' else
					cavlc_vl when cavlc_valid='1' else
					b"01000";			--8 bits (1 + 7 for align)
	tobytes_valid <= header_valid or align_VALID or cavlc_valid;
	--
process(CLK2)	--nout/nin processing for CAVLC
begin
	if rising_edge(CLK2) then
		if xbuffer_NLOAD='1' then
			ninleft(conv_integer(xbuffer_NY)) <= cavlc_NOUT;
			nintop(conv_integer(ninx&xbuffer_NX)) <= cavlc_NOUT;
		else
			ninl <= ninleft(conv_integer(xbuffer_NY));
			nint <= nintop(conv_integer(ninx&xbuffer_NX));
		end if;
		if NEWLINE='1' then
			ninx <= (others => '0');
		elsif xbuffer_NXINC='1' then
			ninx <= ninx+1;
		end if;
	end if;
end process;
	cavlc_NIN <=
		ninl when xbuffer_NV=1 else
		nint when xbuffer_NV=2 else
		ninsum(5 downto 1) when xbuffer_NV=3 else
		(others=>'0');
	ninsum <= ('0'&ninl) + ('0'&nint) + 1;
	--
process(CLK2)	--feedback
begin
	if rising_edge(CLK2) then
		--feedback: set toppix
		if recon_FBSTROBE='1' then
			toppix(conv_integer(mbx & intra4x4_XXO)) <= recon_FEEDB;
		end if;
		if intra4x4_MSTROBEO='1' then
			topmode(conv_integer(mbx & intra4x4_XXO)) <= intra4x4_MODEO;
		end if;
		if NEWLINE='1' then
			mbx <= (others => '0');
		elsif intra4x4_XXINC='1' then
			mbx <= mbx + 1;
		end if;
		--
		--chroma feedback: set toppixcc
		if recon_FBCSTROBE='1' then
			toppixcc(conv_integer(mbxcc & intra8x8cc_XXO)) <= recon_FEEDB;
		end if;
		if NEWLINE='1' then
			mbxcc <= (others => '0');
		elsif intra8x8cc_XXINC='1' then
			mbxcc <= mbxcc + 1;
		end if;
	end if;
end process;
	--
end hw;