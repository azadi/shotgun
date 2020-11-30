#!/usr/bin/env dnsjit

-- limit-clients.lua: randomize which clients (IPs) will be included in output
--
-- Every unique IP (client) has the given chance to appear in the output file.
-- If a client appears, all of its packets remain intact (up to the specified
-- duration). If a client doesn't appear in the output, none of its packets
-- will.
--
-- This script can only scale-down (limit) the number of clients, i.e. the
-- chance must be in range 0 to 1.

local ffi = require("ffi")
local input = require("dnsjit.input.pcap").new()
local output = require("dnsjit.output.pcap").new()
local layer = require("dnsjit.filter.layer").new()
local object = require("dnsjit.core.objects")
local log = require("dnsjit.core.log").new("extract-clients.lua")
local getopt = require("dnsjit.lib.getopt").new({
	{ "r", "read", "", "input file to read", "?" },
	{ "w", "write", "", "output file to write", "?" },
	{ "d", "duration", 0, "duration of output (in seconds, 0 means entire file)", "?" },
	{ "l", "limit", 1.0, "chance for each client to appear, 0 to 1", "?" },
	{ "", "seed", 0, "seed for RNG", "?" },
})

local SNAPLEN = 66000
local LINKTYPE = 12  -- DLT_RAW in Linux, see https://github.com/the-tcpdump-group/libpcap/blob/master/pcap/dlt.h

log:enable("all")

-- Parse arguments
local args = {}
getopt:parse()
args.read = getopt:val("r")
args.write = getopt:val("w")
args.duration = getopt:val("d")
args.limit = getopt:val("l")
args.seed = getopt:val("seed")

-- Display help
if getopt:val("help") then
	getopt:usage()
	return
end

-- Check arguments
if args.duration < 0 then
	log:fatal("duration can't be negative")
elseif args.duration == 0 then
	args.duration = math.huge
end
if args.limit <= 0 then
	log:fatal("limit must be greater than 0")
elseif args.limit > 1 then
	log:fatal("limit can't be greater than 1")
end
math.randomseed(args.seed)

-- Set up input
if args.read ~= "" then
	if input:open_offline(args.read) ~= 0 then
		log:fatal("failed to open input PCAP " .. args.read)
	end
	log:notice("using input PCAP " .. args.read)
else
	getopt:usage()
	log:fatal("input must be specified, use -r")
end
layer:producer(input)
local produce, pctx = layer:produce()

-- Set up output
if args.write ~= "" then
	if output:open(args.write, LINKTYPE, SNAPLEN) ~= 0 then
		log:fatal("failed to open chunk file " .. args.write)
	else
		log:notice("wiring output PCAP: " .. args.write)
	end
else
	getopt:usage()
	log:fatal("output must be specified, use -w")
end
local write, writectx = output:receive()

local clients = {}
local n_present = 0
local now_ms, since_ms, until_ms


local obj, obj_pcap_in, obj_ip, obj_pl, src_ip, ip_len, present
while true do
	obj = produce(pctx)
	if obj == nil then break end

	ip_len = 4
	obj_ip = obj:cast_to(object.IP)
	if obj_ip == nil then
		obj_ip = obj:cast_to(object.IP6)
		ip_len = 16
	end

	obj_pl = obj:cast_to(object.PAYLOAD)
	obj_pcap_in = obj:cast_to(object.PCAP)
	if obj_ip ~= nil and obj_pl ~= nil and obj_pcap_in ~= nil then
		now_ms = tonumber(obj_pcap_in.ts.sec) * 1e3 + tonumber(obj_pcap_in.ts.nsec) * 1e-6
		if until_ms == nil then
			since_ms = now_ms
			until_ms = now_ms + args.duration * 1e3
		elseif now_ms >= until_ms then
			break
		end

		src_ip = ffi.string(obj_ip.src, ip_len)
		present = clients[src_ip]
		if present == nil then
			present = math.random() < args.limit
			if present then
				n_present = n_present + 1
			end
			clients[src_ip] = present
		end

		if present then
			write(writectx, obj)
		end
	end
end

local duration_s = (now_ms - since_ms) / 1e3

log:info(string.format("    since_ms: %d", since_ms))
log:info(string.format("    until_ms: %d", now_ms))
log:info(string.format("    duration_s: %.3f", duration_s))
log:info(string.format("    number of clients: %d", n_present))
