------------------------------------------------------------------------------
--  This file is part of an extension to the GRLIB VHDL IP library.
--  Copyright (C) 2013, System Level Design (SLD) group @ Columbia University
--
--  GRLIP is a Copyright (C) 2008 - 2013, Aeroflex Gaisler
--
--  This program is free software; you can redistribute it and/or modify
--  it under the terms of the GNU General Public License as published by
--  the Free Software Foundation; either version 2 of the License, or
--  (at your option) any later version.
--
--  This program is distributed in the hope that it will be useful,
--  but WITHOUT ANY WARRANTY; without even the implied warranty of
--  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
--  GNU General Public License for more details.
--
--  To receive a copy of the GNU General Public License, write to the Free
--  Software Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA
--  02111-1307  USA.
-----------------------------------------------------------------------------
-- Entity:  mem_noc2ahbm
-- File:    mem_noc2ahbm.vhd
-- Authors: Paolo Mantovani - SLD @ Columbia University
-- Description:	Network interface to Amba 2.0 Master interface
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

--pragma translate_off
use STD.textio.all;
use ieee.std_logic_textio.all;
--pragma translate_on

use work.amba.all;
use work.stdlib.all;
use work.sld_devices.all;
use work.devices.all;

use work.gencomp.all;
use work.genacc.all;

use work.nocpackage.all;
use work.cachepackage.all;

entity mem_noc2ahbm is
  generic (
    tech        : integer := virtex7;
    ncpu        : integer := 4;
    hindex      : integer range 0 to NAHBSLV-1 := 4;
    local_y     : local_yx;
    local_x     : local_yx;
    cacheline   : integer;
    l2_cache_en : integer := 0;
    destination : integer := 0);        -- 0: mem
                                        -- 1: DSU
  port (
    rst      : in  std_ulogic;
    clk      : in  std_ulogic;
    ahbmi    : in  ahb_mst_in_type;
    ahbmo    : out ahb_mst_out_type;

    -- NoC1->tile
    coherence_req_rdreq                 : out  std_ulogic;
    coherence_req_data_out              : in  noc_flit_type;
    coherence_req_empty                 : in  std_ulogic;
    -- tile->NoC2
    coherence_fwd_wrreq             : out std_ulogic;
    coherence_fwd_data_in           : out noc_flit_type;
    coherence_fwd_full              : in  std_ulogic;
    -- tile->NoC3
    coherence_rsp_snd_wrreq            : out std_ulogic;
    coherence_rsp_snd_data_in          : out noc_flit_type;
    coherence_rsp_snd_full             : in  std_ulogic;
    -- NoC4->tile
    dma_rcv_rdreq                       : out std_ulogic;
    dma_rcv_data_out                    : in  noc_flit_type;
    dma_rcv_empty                       : in  std_ulogic;
    -- tile->NoC4
    dma_snd_wrreq                       : out std_ulogic;
    dma_snd_data_in                     : out noc_flit_type;
    dma_snd_full                        : in  std_ulogic;
    dma_snd_atleast_4slots              : in  std_ulogic;
    dma_snd_exactly_3slots              : in  std_ulogic);

end mem_noc2ahbm;

architecture rtl of mem_noc2ahbm is

  -- If length is not received, then use fix length of 4 words.
  -- The accelerators will always provide a length.
  -- Protection info is in the reserved field of the header
  -- determine the destination tile for the response based on the header origin
  -- x and y info
  type ahbm_fsm is (receive_header,
                    receive_address, cacheable_rd_request, send_header,
                    send_address, send_data, cacheable_wr_request, write_data,
                    write_last_data, write_complete,
                    dma_receive_address, dma_rd_request, dma_send_header,
                    dma_send_data, dma_wr_request, dma_write_data,
                    dma_receive_rdlength, dma_send_busy, dma_wait_busy,
                    dma_write_busy, write_busy, send_put_ack, send_put_ack_address);

  -- RSP_DATA
  signal header : noc_flit_type;
  signal header_reg : noc_flit_type;
  signal sample_header : std_ulogic;

  -- DMA_TO_DEV
  signal dma_header : noc_flit_type;
  signal sample_dma_header : std_ulogic;

  -- common
  type reg_type is record
                     msg     : noc_msg_type;
                     hprot   : std_logic_vector(3 downto 0);
                     hsize   : std_logic_vector(2 downto 0);
                     grant   : std_ulogic;
                     ready   : std_ulogic;
                     resp    : std_logic_vector(1 downto 0);
                     addr    : std_logic_vector(31 downto 0);
                     flit    : noc_flit_type;
                     hwdata  : std_logic_vector(31 downto 0);
                     state   : ahbm_fsm;
                     count   : integer;
                     bufen   : std_ulogic;
                     bufwren : std_ulogic;
                     htrans  : std_logic_vector(1 downto 0);
                     hburst  : std_logic_vector(2 downto 0);
                     hwrite  : std_ulogic;
                     hbusreq : std_ulogic;
                   end record;
  constant reg_none : reg_type := (
    msg     => REQ_GETS_W,
    hprot   => "0011",
    hsize   => HSIZE_WORD,
    grant   => '0',
    ready   => '0',
    resp    => HRESP_OKAY,
    addr    => (others => '0'),
    flit    => (others => '0'),
    hwdata  => (others => '0'),
    state   => receive_header,
    count   => 0,
    bufen   => '0',
    bufwren => '0',
    htrans  => HTRANS_IDLE,
    hburst  => HBURST_INCR,
    hwrite  => '0',
    hbusreq => '0');

  signal r, rin : reg_type;

begin  -- rtl

  -----------------------------------------------------------------------------
  -- Create packet for response messages to GETS
  -----------------------------------------------------------------------------
  make_rsp_snd_packet: process (coherence_req_data_out)
    variable input_msg_type : noc_msg_type;
    variable preamble : noc_preamble_type;
    variable msg_type : noc_msg_type;
    variable header_v : noc_flit_type;
    variable reserved : reserved_field_type;
    variable origin_y, origin_x : local_yx;
  begin  -- process make_packet
    input_msg_type := get_msg_type(coherence_req_data_out);
    if destination /= 0 then
      msg_type := AHB_RD;
      preamble := PREAMBLE_HEADER;
    else
      if l2_cache_en = 1 then
        -- L2 cache enabled, but no LLC present
        if input_msg_type = REQ_PUTS or input_msg_type = REQ_PUTM then
          msg_type := RSP_PUT_ACK;
          preamble := PREAMBLE_HEADER;
        else
          -- TODO: why RSP_EDATA doesn't work?
          msg_type := RSP_DATA;
          preamble := PREAMBLE_HEADER;
        end if;
      else
        -- no L2 cache
        msg_type := RSP_DATA;
        preamble := PREAMBLE_HEADER;
      end if;
    end if;
    reserved := (others => '0');
    header_v := (others => '0');
    origin_y := get_origin_y(coherence_req_data_out);
    origin_x := get_origin_x(coherence_req_data_out);
    header_v := create_header(local_y, local_x, origin_y, origin_x, msg_type, reserved);
    header_v(NOC_FLIT_SIZE - 1 downto NOC_FLIT_SIZE - PREAMBLE_WIDTH) := preamble;
    header <= header_v;
  end process make_rsp_snd_packet;
  -----------------------------------------------------------------------------
  -- Create packet for DMA response message
  -----------------------------------------------------------------------------
  make_dma_packet: process (dma_rcv_data_out)
    variable msg_type : noc_msg_type;
    variable header_v : noc_flit_type;
    variable reserved : reserved_field_type;
    variable origin_y, origin_x : local_yx;
  begin  -- process make_packet
    msg_type := DMA_TO_DEV;
    reserved := (others => '0');
    header_v := (others => '0');
    origin_y := get_origin_y(dma_rcv_data_out);
    origin_x := get_origin_x(dma_rcv_data_out);
    header_v := create_header(local_y, local_x, origin_y, origin_x, msg_type, reserved);
    dma_header <= header_v;
  end process make_dma_packet;


  -----------------------------------------------------------------------------
  -- Registers
  -----------------------------------------------------------------------------
  process (clk, rst)
  begin  -- process
    if rst = '0' then                   -- asynchronous reset (active low)
      header_reg <= (others => '0');
    elsif clk'event and clk = '1' then  -- rising clock edge
      if sample_header = '1' then
        header_reg <= header;
      elsif sample_dma_header = '1' then
        header_reg <= dma_header;
      end if;
    end if;
  end process;

  -----------------------------------------------------------------------------
  -- AHB handling
  -----------------------------------------------------------------------------

  --TODO: handle other services
  -- so far coherence_req_, coherence_rsp_snd_full are handled
  ahb_roundtrip: process (ahbmi, r,
                          coherence_req_empty, coherence_req_data_out,
                          coherence_rsp_snd_full,
                          header_reg,
                          dma_rcv_empty, dma_rcv_data_out,
                          dma_snd_full, dma_snd_atleast_4slots, dma_snd_exactly_3slots,
                          coherence_fwd_full)
    variable v : reg_type;
    variable reserved : reserved_field_type;
    variable preamble, dma_preamble : noc_preamble_type;
  begin  -- process ahb_roundtrip
    -- Default ahbmo assignment
    v := r;
    v.grant := ahbmi.hgrant(hindex);
    v.ready := ahbmi.hready;
    v.resp  := ahbmi.hresp;

    reserved := (others => '0');
    preamble := get_preamble(coherence_req_data_out);
    dma_preamble := get_preamble(dma_rcv_data_out);

    sample_header <= '0';
    sample_dma_header <= '0';

    coherence_req_rdreq <= '0';
    coherence_rsp_snd_data_in <= (others => '0');
    coherence_rsp_snd_wrreq <= '0';

    coherence_fwd_data_in <= (others => '0');
    coherence_fwd_wrreq <= '0';

    dma_rcv_rdreq <= '0';
    dma_snd_data_in <= (others => '0');
    dma_snd_wrreq <= '0';

    case r.state is
      when receive_header => if coherence_req_empty = '0' then
                               coherence_req_rdreq <= '1';
                               -- Sample request info
                               v.msg := get_msg_type(coherence_req_data_out);
                               reserved := get_reserved_field(coherence_req_data_out);
                               v.hprot := reserved(3 downto 0);
                               sample_header <= '1';
                               v.state := receive_address;
                             elsif dma_rcv_empty = '0' then
                               dma_rcv_rdreq <= '1';
                               -- Sample DMA request
                               v.msg := get_msg_type(dma_rcv_data_out);
                               reserved := get_reserved_field(dma_rcv_data_out);
                               v.hprot := reserved(3 downto 0);
                               sample_dma_header <= '1';
                               v.state := dma_receive_address;
                             end if;

      when receive_address => if coherence_req_empty = '0' then
                                coherence_req_rdreq <= '1';
                                v.addr := coherence_req_data_out(31 downto 0);
                                if (r.msg = REQ_GETS_W or r.msg = REQ_GETS_HW or r.msg = REQ_GETS_B)
                                  or ((r.msg = REQ_GETM_W) and (l2_cache_en /= 0)) then
                                  -- Use default size: cacheline
                                  v.count := cacheline;
                                  v.state := cacheable_rd_request;
                                elsif (r.msg = REQ_GETM_W or r.msg = REQ_GETM_HW or r.msg = REQ_GETM_B) and (l2_cache_en = 0) then
                                  -- Writes don't need size. Stop when tail appears.
                                  v.state := cacheable_wr_request;
                                  -- TODO: add other requests handling!
                                elsif r.msg = REQ_PUTS or r.msg = REQ_PUTM then
                                  v.state := send_put_ack;
                                else
                                  v.state := receive_header;
                                end if;
                              end if;

      when dma_receive_address => if dma_rcv_empty = '0' then
                                    dma_rcv_rdreq <= '1';
                                    v.addr := dma_rcv_data_out(31 downto 0);
                                    if r.msg = DMA_TO_DEV then
                                      v.state := dma_receive_rdlength;
                                    else
                                      -- Writes don't need size. Stop when tail appears.
                                      v.state := dma_wr_request;
                                    end if;
                                  end if;

      when dma_receive_rdlength => if dma_rcv_empty = '0' then
                                     dma_rcv_rdreq <= '1';
                                     v.count := conv_integer(dma_rcv_data_out(31 downto 0));
                                     v.state := dma_rd_request;
                                   end if;

      when cacheable_rd_request => if r.msg = REQ_GETS_B then
                                     v.hsize := HSIZE_BYTE;
                                   elsif r.msg = REQ_GETS_HW then
                                     v.hsize := HSIZE_HWORD;
                                   else
                                     v.hsize := HSIZE_WORD;
                                   end if;
                                   if coherence_rsp_snd_full = '0' then
                                     if ((r.count = 1) and (v.grant = '1')
                                         and (v.ready  = '1')) then
                                       -- Owning already address
                                       -- Single word transfer: no request
                                       -- Send header
                                       v.hburst := HBURST_SINGLE;
                                       v.htrans := HTRANS_NONSEQ;
                                       v.state := send_header;
                                     elsif ((v.grant = '1') and (v.ready = '1')) then
                                       -- Owning already address
                                       -- More than one element burst
                                       -- Send header
                                       v.hbusreq := '1';
                                       v.hburst := HBURST_INCR;
                                       v.htrans := HTRANS_NONSEQ;
                                       v.state := send_header;
                                     else
                                       -- Need to get ownership of the bus
                                       if r.count = 1 then
                                         v.hburst := HBURST_SINGLE;
                                       else
                                         v.hburst := HBURST_INCR;
                                       end if;
                                       v.hbusreq := '1';
                                       v.htrans := HTRANS_NONSEQ;
                                     end if;
                                   end if;

      when dma_rd_request       => v.hsize := HSIZE_WORD;
                                   if dma_snd_atleast_4slots = '1' then
                                     if ((r.count = 1) and (v.grant = '1')
                                         and (v.ready  = '1')) then
                                       -- Owning already address
                                       -- Single word transfer: no request
                                       -- Send header
                                       v.hburst := HBURST_SINGLE;
                                       v.htrans := HTRANS_NONSEQ;
                                       v.state := dma_send_header;
                                     elsif ((v.grant = '1') and (v.ready = '1')) then
                                       -- Owning already address
                                       -- More than one element burst
                                       -- Send header
                                       v.hbusreq := '1';
                                       v.hburst := HBURST_INCR;
                                       v.htrans := HTRANS_NONSEQ;
                                       v.state := dma_send_header;
                                     else
                                       -- Need to get ownership of the bus
                                       if r.count = 1 then
                                         v.hburst := HBURST_SINGLE;
                                       else
                                         v.hburst := HBURST_INCR;
                                       end if;
                                       v.hbusreq := '1';
                                       v.htrans := HTRANS_NONSEQ;
                                     end if;
                                   end if;

      when send_header => if (v.ready = '1') then
                            -- Data bus granted
                            -- Send header
                            coherence_rsp_snd_data_in <= header_reg;
                            coherence_rsp_snd_wrreq <= '1';
                            -- Updated address and control bus
                            v.addr := r.addr + 4;
                            v.count := r.count - 1;
                            if r.count = 1 then
                              v.hbusreq := '0';
                              v.htrans := HTRANS_IDLE;
                            else
                              if r.count = 2 then
                                v.hbusreq := '0';
                              end if;
                              v.htrans := HTRANS_SEQ;
                            end if;

                            if l2_cache_en = 0 then
                              v.state := send_data;
                            else
                              v.state := send_address;
                            end if;
                          end if;

      when send_put_ack => if (coherence_rsp_snd_full = '0') then
                             coherence_rsp_snd_data_in <= header_reg;
                             coherence_rsp_snd_wrreq <= '1';
                             v.state := send_put_ack_address;
                           end if;

      when send_put_ack_address => if (coherence_rsp_snd_full = '0') then
                                     coherence_rsp_snd_data_in <= PREAMBLE_TAIL & r.addr;
                                     coherence_rsp_snd_wrreq <= '1';
                                     if r.msg = REQ_PUTM then
                                       v.state := cacheable_wr_request;
                                     else
                                       v.state := receive_header;
                                     end if;
                                   end if;
    
      when dma_send_header => if (v.ready = '1') then
                            -- Data bus granted
                            -- Send header
                            dma_snd_data_in <= header_reg;
                            dma_snd_wrreq <= '1';
                            -- Updated address and control bus
                            v.addr := r.addr + 4;
                            v.count := r.count - 1;
                            if r.count = 1 then
                              v.hbusreq := '0';
                              v.htrans := HTRANS_IDLE;
                            else
                              if r.count = 2 then
                                v.hbusreq := '0';
                              end if;
                              v.htrans := HTRANS_SEQ;
                            end if;
                            v.state := dma_send_data;
                          end if;

      when send_address => v.htrans := HTRANS_BUSY;
                           if (coherence_rsp_snd_full = '0') then
                             coherence_rsp_snd_data_in <= PREAMBLE_BODY & r.addr;
                             coherence_rsp_snd_wrreq <= '1';

                             v.state := send_data;
                           end if;
                              
      when send_data => if (v.ready = '1') then
                          if coherence_rsp_snd_full = '1' then
                            v.htrans := HTRANS_BUSY;
                          else
                            -- Send data to noc
                            coherence_rsp_snd_wrreq <= '1';
                            coherence_rsp_snd_data_in <= PREAMBLE_BODY & ahbreadword(ahbmi.hrdata, r.hsize);
                            -- Update address and control bus
                            v.addr := r.addr + 4;
                            v.count := r.count - 1;
                            if r.count = 2 then
                              v.hbusreq := '0';
                              v.htrans := HTRANS_SEQ;
                            elsif r.count = 1 then
                              v.hbusreq := '0';
                              v.htrans := HTRANS_IDLE;
                            elsif r.count = 0 then
                              coherence_rsp_snd_data_in <= PREAMBLE_TAIL & ahbreadword(ahbmi.hrdata, r.hsize);
                              v.state := receive_header;
                            else
                              v.htrans := HTRANS_SEQ;
                            end if;
                          end if;
                        end if;

      when dma_send_data =>
        if (v.ready = '1') then
            -- Send data to noc
            dma_snd_wrreq <= '1';
            dma_snd_data_in <= PREAMBLE_BODY & ahbreadword(ahbmi.hrdata, r.hsize);
            -- Update address and control bus
            v.addr := r.addr + 4;
            v.count := r.count - 1;
            if r.count = 2 then
              v.hbusreq := '0';
              v.htrans := HTRANS_SEQ;
            elsif r.count = 1 then
              v.hbusreq := '0';
              v.htrans := HTRANS_IDLE;
            elsif r.count = 0 then
              dma_snd_data_in <= PREAMBLE_TAIL & ahbreadword(ahbmi.hrdata, r.hsize);
              v.state := receive_header;
            else
              if dma_snd_exactly_3slots = '1' then
                v.htrans := HTRANS_BUSY;
                v.state := dma_send_busy;
              else
                v.htrans := HTRANS_SEQ;
              end if;
            end if;
        end if;

      when dma_send_busy =>
        if (v.ready = '1') then
          dma_snd_wrreq <= '1';
          dma_snd_data_in <= PREAMBLE_BODY & ahbreadword(ahbmi.hrdata, r.hsize);
          v.count := r.count - 1;
          if r.count = 2 then
            v.hbusreq := '0';
          end if;
          v.state := dma_wait_busy;
        end if;

      when dma_wait_busy =>
        if dma_snd_exactly_3slots = '1' or dma_snd_atleast_4slots = '1' then
          v.htrans := HTRANS_SEQ;
        end if;
        if (r.htrans = HTRANS_SEQ and v.ready = '1') then
          v.addr := r.addr + 4;
          v.state := dma_send_data;
        end if;

      when cacheable_wr_request => if r.msg = REQ_GETM_B then
                                     v.hsize := HSIZE_BYTE;
                                   elsif r.msg = REQ_GETM_HW then
                                     v.hsize := HSIZE_HWORD;
                                   else
                                     v.hsize := HSIZE_WORD;
                                   end if;
                                   if coherence_req_empty = '0' then
                                     if ((preamble = PREAMBLE_TAIL) and
                                         (v.grant = '1') and (v.ready = '1')) then
                                       -- Owning already address bus
                                       -- Single word transfer: no request
                                       -- Prefetch
                                       coherence_req_rdreq <= '1';
                                       v.flit := coherence_req_data_out;
                                       v.hburst := HBURST_SINGLE;
                                       v.htrans := HTRANS_NONSEQ;
                                       v.hwrite := '1';
                                       v.state := write_last_data;
                                     elsif ((v.grant = '1') and (v.ready = '1')) then
                                       -- Owning already address bus
                                       -- More than one element burst
                                       -- Prefetch
                                       coherence_req_rdreq <= '1';
                                       v.flit := coherence_req_data_out;
                                       v.hbusreq := '1';
                                       v.hburst := HBURST_INCR;
                                       v.htrans := HTRANS_NONSEQ;
                                       v.hwrite := '1';
                                       v.state := write_data;
                                     else
                                       -- Need to get ownership of the bus
                                       if (preamble = PREAMBLE_TAIL) then
                                         v.hburst := HBURST_SINGLE;
                                       else
                                         v.hburst := HBURST_INCR;
                                       end if;
                                       v.hbusreq := '1';
                                       v.htrans := HTRANS_NONSEQ;
                                       v.hwrite := '1';
                                     end if;
                                   end if;

      when dma_wr_request       => v.hsize := HSIZE_WORD;
                                   if dma_rcv_empty = '0' then
                                     if ((dma_preamble = PREAMBLE_TAIL) and
                                         (v.grant = '1') and (v.ready = '1')) then
                                       -- Owning already address bus
                                       -- Single word transfer: no request
                                       -- Prefetch
                                       dma_rcv_rdreq <= '1';
                                       v.flit := dma_rcv_data_out;
                                       v.hburst := HBURST_SINGLE;
                                       v.htrans := HTRANS_NONSEQ;
                                       v.hwrite := '1';
                                       v.state := write_last_data;
                                     elsif ((v.grant = '1') and (v.ready = '1')) then
                                       -- Owning already address bus
                                       -- More than one element burst
                                       -- Prefetch
                                       dma_rcv_rdreq <= '1';
                                       v.flit := dma_rcv_data_out;
                                       v.hbusreq := '1';
                                       v.hburst := HBURST_INCR;
                                       v.htrans := HTRANS_NONSEQ;
                                       v.hwrite := '1';
                                       v.state := dma_write_data;
                                     else
                                       -- Need to get ownership of the bus
                                       if (dma_preamble = PREAMBLE_TAIL) then
                                         v.hburst := HBURST_SINGLE;
                                       else
                                         v.hburst := HBURST_INCR;
                                       end if;
                                       v.hbusreq := '1';
                                       v.htrans := HTRANS_NONSEQ;
                                       v.hwrite := '1';
                                     end if;
                                   end if;

      when write_data =>
        if (v.ready = '1') then
          -- Write data to memory
          v.hwdata := r.flit(31 downto 0);
          -- Update address and control
          v.addr := r.addr + 4;
          if coherence_req_empty = '1' then
            v.htrans := HTRANS_BUSY;
            v.state := write_busy;
          else
            v.htrans := HTRANS_SEQ;
            if (preamble = PREAMBLE_TAIL) then
              v.hbusreq := '0';
              v.state := write_last_data;
            end if;
            -- Prefetch
            coherence_req_rdreq <= '1';
            v.flit := coherence_req_data_out;
          end if;
        end if;

      when dma_write_data =>
        if (v.ready = '1') then
          -- Write data to memory
          v.hwdata := r.flit(31 downto 0);
          -- Upda`te address and control
          v.addr := r.addr + 4;
          if dma_rcv_empty = '1' then
            v.htrans := HTRANS_BUSY;
            v.state := dma_write_busy;
          else
            v.htrans := HTRANS_SEQ;
            if (dma_preamble = PREAMBLE_TAIL) then
              v.hbusreq := '0';
              v.state := write_last_data;
            end if;
            -- Prefetch
            dma_rcv_rdreq <= '1';
            v.flit := dma_rcv_data_out;
          end if;
        end if;

      when write_busy =>
        if (v.ready = '1' and coherence_req_empty = '0') then
          v.htrans := HTRANS_SEQ;
          if (preamble = PREAMBLE_TAIL) then
            v.hbusreq := '0';
            v.state := write_last_data;
          else
            v.state := write_data;
          end if;
          -- Prefetch
          coherence_req_rdreq <= '1';
          v.flit := coherence_req_data_out;
        end if;

      when dma_write_busy =>
        if (v.ready = '1' and dma_rcv_empty = '0') then
          v.htrans := HTRANS_SEQ;
          if (dma_preamble = PREAMBLE_TAIL) then
            v.hbusreq := '0';
            v.state := write_last_data;
          else
            v.state := dma_write_data;
          end if;
          -- Prefetch
          dma_rcv_rdreq <= '1';
          v.flit := dma_rcv_data_out;
        end if;

      when write_last_data => if (v.ready = '1') then
                                v.hwdata := r.flit(31 downto 0);
                                v.htrans := HTRANS_IDLE;
                                v.hwrite := '0';
                                v.state := write_complete;
                              end if;

      when write_complete => if (v.ready = '1') then
                               v.state := receive_header;
                             end if;

      when others => v.state := receive_header;

    end case;

    rin <= v;
    ahbmo.hbusreq <= r.hbusreq;
    ahbmo.hlock   <= '0';
    ahbmo.htrans  <= r.htrans;
    ahbmo.haddr   <= r.addr;
    ahbmo.hwrite  <= r.hwrite;
    ahbmo.hsize   <= r.hsize;
    ahbmo.hburst  <= r.hburst;
    ahbmo.hprot   <= r.hprot;
    ahbmo.hwdata  <= ahbdrivedata(r.hwdata);
    ahbmo.hirq    <= (others => '0');
    ahbmo.hconfig <= hconfig_none;
    ahbmo.hindex  <= hindex;

  end process ahb_roundtrip;

  -- Update FSM state
  process (clk, rst)
  begin  -- process
    if rst = '0' then                   -- asynchronous reset (active low)
      r <= reg_none;
    elsif clk'event and clk = '1' then  -- rising clock edge
      r <= rin;
    end if;
  end process;

end rtl;
