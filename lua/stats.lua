--- IO stats for devices
local mod = {}

local phobos    = require "phobos"
local dpdk      = require "dpdk"
local device    = require "device"
local log       = require "log"
local colors    = require "colors"

function mod.average(data)
	local sum = 0
	for i, v in ipairs(data) do
		sum = sum + v
	end
	return sum / #data
end

function mod.median(data)
	return mod.percentile(data, 50)
end

function mod.percentile(data, p)
	local sortedData = { }
	for k, v in ipairs(data) do
		sortedData[k] = v
	end
	table.sort(sortedData)
	return sortedData[math.ceil(#data * p / 100)]
end

function mod.stdDev(data)
	local avg = mod.average(data)
	local sum = 0
	for i, v in ipairs(data) do
		sum = sum + (v - avg) ^ 2
	end
	return (sum / (#data - 1)) ^ 0.5
end

function mod.sum(data)
	local sum = 0
	for i, v in ipairs(data) do
		sum = sum + v
	end
	return sum
end

function mod.addStats(data, ignoreFirstAndLast)
	local copy = { }
	if ignoreFirstAndLast then
		for i = 2, #data - 1 do
			copy[i - 1] = data[i]
		end
	else
		for i = 1, #data do
			copy[i] = data[i]
		end
	end
	data.avg = mod.average(copy)
	data.stdDev = mod.stdDev(copy)
	data.median = mod.median(copy)
	data.sum = mod.sum(copy)
end

local colors = {
	RX = "cyan",
	TX = "blue"
}
local function getPlainUpdate(direction)
	return function(stats, file, total, mpps, mbit, wireMbit)
		file:write(("%s[%s] %s%s: %.2f Mpps, %.0f Mbit/s (%.0f Mbit/s with framing)\n"):format(
			getColorCode(colors[direction]), stats.name, direction, getColorCode(),
			mpps, mbit, wireMbit
		))
		file:flush()
	end
end

local function getPlainFinal(direction)
	return function(stats, file)
		file:write(("[%s] %s: %.2f (StdDev %.2f) Mpps, %.0f (StdDev %.0f) Mbit/s (%.0f Mbit/s with framing), total %d packets with %d bytes (incl. CRC)\n"):format(
			stats.name, direction,
			stats.mpps.avg, stats.mpps.stdDev,
			stats.mbit.avg, stats.mbit.stdDev,
			stats.wireMbit.avg,
			stats.total, stats.totalBytes
		))
		file:flush()
	end
end

local formatters = {}
formatters["plain"] = {
	rxStatsInit = function() end, -- nothing for plain, machine-readable formats can print a header here
	rxStatsUpdate = getPlainUpdate("RX"),
	rxStatsFinal = getPlainFinal("RX"),

	txStatsInit = function() end,
	txStatsUpdate = getPlainUpdate("TX"),
	txStatsFinal = getPlainFinal("TX"),
}

-- Formatter that does nothing
formatters["nil"] = {
	rxStatsInit = function() end,
	rxStatsUpdate = function() end,
	rxStatsFinal = function() end,

	txStatsInit = function() end,
	txStatsUpdate = function() end,
	txStatsFinal = function () end,
}

formatters["CSV"] = formatters["plain"] -- TODO

--- base constructor for rx and tx counters
local function newCounter(ctrType, name, dev, format, file)
	format = format or "CSV"
	file = file or io.stdout
	local closeFile = false
	if type(file) == "string" then
		file = io.open(file, "w+")
		closeFile = true
	end
	if not formatters[format] then
		log:fatal("Unsupported output format " .. format)
	end
	return {
		name = name,
		dev = dev,
		format = format,
		file = file,
		closeFile = closeFile,
		total = 0,
		totalBytes = 0,
		current = 0,
		currentBytes = 0,
		mpps = {},
		mbit = {},
		wireMbit = {},
	}
end

-- base class for rx and tx counters

local function printStats(self, statsType, event, ...)
	local func = formatters[self.format][statsType .. event]
	if func then
		func(self, self.file, ...)
	else
		print("[Missing formatter for " .. self.format .. "]", self.name, statsType, event, ...)
	end
end

local function updateCounter(self, time, pkts, bytes, dontPrint)
	if not self.lastUpdate then
		-- first call, save current stats but do not print anything
		self.total, self.totalBytes = pkts, bytes
		self.lastUpdate = time
		self:print("Init")
		return
	end
	local elapsed = time - self.lastUpdate
	self.lastUpdate = time
	local mpps = (pkts - self.total) / elapsed / 10^6
	local mbit = (bytes - self.totalBytes) / elapsed / 10^6 * 8
	local wireRate = mbit + (mpps * 20 * 8)
	self.total = pkts
	self.totalBytes = bytes
	if not dontPrint then
		self:print("Update", self.total, mpps, mbit, wireRate)
	end
	table.insert(self.mpps, mpps)
	table.insert(self.mbit, mbit)
	table.insert(self.wireMbit, wireRate)
end

local function getStats(self)
	mod.addStats(self.mpps, true)
	mod.addStats(self.mbit, true)
	mod.addStats(self.wireMbit, true)
	return self.mpps, self.mbit, self.wireMbit, self.total, self.totalBytes
end

local function finalizeCounter(self, sleep)
	-- wait for any remaining packets to arrive/be sent if necessary
	phobos.sleepMillis(sleep)
	-- last stats are probably complete nonsense, especially if sleep ~= 0
	-- we just do this to get the correct totals
	local pkts, bytes = self:getThroughput()
	updateCounter(self, phobos.getTime(), pkts, bytes, true)
	mod.addStats(self.mpps, true)
	mod.addStats(self.mbit, true)
	mod.addStats(self.wireMbit, true)
	self:print("Final")
	if self.closeFile then
		self.file:close()
	end
end


local rxCounter = {} -- base class
local devRxCounter = setmetatable({}, rxCounter)
local pktRxCounter = setmetatable({}, rxCounter)
local manualRxCounter = setmetatable({}, rxCounter)
rxCounter.__index = rxCounter
devRxCounter.__index = devRxCounter
pktRxCounter.__index = pktRxCounter
manualRxCounter.__index = manualRxCounter

--- Create a new rx counter using device statistics registers.
--- @param name the name of the counter, included in the output. defaults to the device name
--- @param dev the device to track
--- @param format the output format, "CSV" (default) and "plain" are currently supported
--- @param file the output file, defaults to standard out
function mod:newDevRxCounter(name, dev, format, file)
	if type(name) == "table" then
		return self:newDevRxCounter(nil, name, dev, format)
	end
	-- use device if queue objects are passed
	dev = dev and dev.dev or dev
	if type(dev) ~= "table" then
		log:fatal("Bad device")
	end
	name = name or tostring(dev):sub(2, -2) -- strip brackets as they are added by the 'plain' output again
	local obj = newCounter("dev", name, dev, format, file)
	obj.sleep = 100
	setmetatable(obj, devRxCounter)
	obj:getThroughput() -- reset stats on the NIC
	return obj
end

--- Create a new rx counter that can be updated by passing packet buffers to it.
--- @param name the name of the counter, included in the output
--- @param format the output format, "CSV" (default) and "plain" are currently supported
--- @param file the output file, defaults to standard out
function mod:newPktRxCounter(name, format, file)
	local obj = newCounter("pkt", name, nil, format, file)
	return setmetatable(obj, pktRxCounter)
end

--- Create a new rx counter that has to be updated manually.
--- @param name the name of the counter, included in the output
--- @param format the output format, "CSV" (default) and "plain" are currently supported
--- @param file the output file, defaults to standard out
function mod:newManualRxCounter(name, format, file)
	local obj = newCounter("manual", name, nil, format, file)
	return setmetatable(obj, manualRxCounter)
end

--- Base class
function rxCounter:finalize(sleep)
	finalizeCounter(self, sleep or self.sleep or 0)
end

function rxCounter:print(event, ...)
	printStats(self, "rxStats", event, ...)
end

function rxCounter:update()
	local time = phobos.getTime()
	if self.lastUpdate and time <= self.lastUpdate + 1 then
		return
	end
	local pkts, bytes = self:getThroughput()
	updateCounter(self, time, pkts, bytes)
end

function rxCounter:getStats()
	-- force an update
	local pkts, bytes = self:getThroughput()
	updateCounter(self, phobos.getTime(), pkts, bytes, true)
	return getStats(self)
end

--- Device-based counter
function devRxCounter:getThroughput() 
    return self.dev:getRxStats() 
end 

--- Packet-based counter
function pktRxCounter:countPacket(buf)
	self.current = self.current + 1
	self.currentBytes = self.currentBytes + buf.pkt_len + 4 -- include CRC
end

function pktRxCounter:getThroughput()
	local pkts, bytes = self.current, self.currentBytes
	self.current, self.currentBytes = 0, 0
	return pkts, bytes
end


--- Manual rx counter
function manualRxCounter:update(pkts, bytes)
	self.current = self.current + pkts
	self.currentBytes = self.currentBytes + bytes
	local time = phobos.getTime()
	if self.lastUpdate and time <= self.lastUpdate + 1 then
		return
	end
	local pkts, bytes = self:getThroughput()
	updateCounter(self, time, pkts, bytes)
end

function manualRxCounter:getThroughput()
	local pkts, bytes = self.current, self.currentBytes
	self.current, self.currentBytes = 0, 0
	return pkts, bytes
end

function manualRxCounter:updateWithSize(pkts, size)
	self.current = self.current + pkts
	self.currentBytes = self.currentBytes + pkts * (size + 4)
	local time = phobos.getTime()
	if self.lastUpdate and time <= self.lastUpdate + 1 then
		return
	end
	local pkts, bytes = self:getThroughput()
	updateCounter(self, time, pkts, bytes)
end


local txCounter = {} -- base class for tx counters
local devTxCounter = setmetatable({}, txCounter)
local pktTxCounter = setmetatable({}, txCounter)
local manualTxCounter = setmetatable({}, txCounter)
txCounter.__index = txCounter
devTxCounter.__index = devTxCounter
pktTxCounter.__index = pktTxCounter
manualTxCounter.__index = manualTxCounter

--- Create a new tx counter using device statistics registers.
--- @param name the name of the counter, included in the output. defaults to the device name
--- @param dev the device to track
--- @param format the output format, "CSV" (default) and "plain" are currently supported
--- @param file the output file, defaults to standard out
function mod:newDevTxCounter(name, dev, format, file)
	if type(name) == "table" then
		return self:newDevTxCounter(nil, name, dev, format)
	end
	-- use device if queue objects are passed
	dev = dev and dev.dev or dev
	if type(dev) ~= "table" then
		log:fatal("Bad device")
	end
	name = name or tostring(dev):sub(2, -2) -- strip brackets as they are added by the 'plain' output again
	local obj = newCounter("dev", name, dev, format, file)
	obj.sleep = 50
	setmetatable(obj, devTxCounter)
	obj:getThroughput() -- reset stats on the NIC
	return obj
end

--- Create a new tx counter that can be updated by passing packet buffers to it.
--- @param name the name of the counter, included in the output
--- @param format the output format, "CSV" (default) and "plain" are currently supported
--- @param file the output file, defaults to standard out
function mod:newPktTxCounter(name, format, file)
	local obj = newCounter("pkt", name, nil, format, file)
	return setmetatable(obj, pktTxCounter)
end

--- Create a new tx counter that has to be updated manually.
--- @param name the name of the counter, included in the output
--- @param format the output format, "CSV" (default) and "plain" are currently supported
--- @param file the output file, defaults to standard out
function mod:newManualTxCounter(name, format, file)
	local obj = newCounter("manual", name, nil, format, file)
	return setmetatable(obj, manualTxCounter)
end

--- Base class
function txCounter:finalize(sleep)
	finalizeCounter(self, sleep or self.sleep or 0)
end

function txCounter:print(event, ...)
	printStats(self, "txStats", event, ...)
end

--- Device-based counter
function txCounter:update()
	local time = phobos.getTime()
	if self.lastUpdate and time <= self.lastUpdate + 1 then
		return
	end
	local pkts, bytes = self:getThroughput()
	updateCounter(self, time, pkts, bytes)
end

--- Get accumulated statistics.
--- Calculate the average throughput.
function txCounter:getStats()
	-- force an update
	local pkts, bytes = self:getThroughput()
	updateCounter(self, phobos.getTime(), pkts, bytes, true)
	return getStats(self)
end

function devTxCounter:getThroughput()
	return self.dev:getTxStats()
end

--- Packet-based counter
function pktTxCounter:countPacket(buf)
	self.current = self.current + 1
	self.currentBytes = self.currentBytes + buf.pkt_len + 4 -- include CRC
end

function pktTxCounter:getThroughput()
	local pkts, bytes = self.current, self.currentBytes
	self.current, self.currentBytes = 0, 0
	return pkts, bytes
end

--- Manual rx counter
function manualTxCounter:update(pkts, bytes)
	self.current = self.current + pkts
	self.currentBytes = self.currentBytes + bytes
	local time = phobos.getTime()
	if self.lastUpdate and time <= self.lastUpdate + 1 then
		return
	end
	local pkts, bytes = self:getThroughput()
	updateCounter(self, time, pkts, bytes)
end

function manualTxCounter:updateWithSize(pkts, size)
	self.current = self.current + pkts
	self.currentBytes = self.currentBytes + pkts * (size + 4)
	local time = phobos.getTime()
	if self.lastUpdate and time <= self.lastUpdate + 1 then
		return
	end
	local pkts, bytes = self:getThroughput()
	updateCounter(self, time, pkts, bytes)
end

function manualTxCounter:getThroughput()
	local pkts, bytes = self.current, self.currentBytes
	self.current, self.currentBytes = 0, 0
	return pkts, bytes
end

--- Start a shared task that counts statistics
--- @param args arguments as table
---    devices: list of devices to track both rx and tx stats
---    rxDevices: list of devices to track rx stats
---    txDevices: list of devices to track tx stats
---    format: output format, cf. stats tracking documentation, default: plain
---    file: file to write to, default: stdout
function mod.startStatsTask(args)
	args.devices = args.devices or {}
	args.rxDevices = args.rxDevices or {}
	args.txDevices = args.txDevices or {}
	phobos.startSharedTask("__PHOBOS_STATS_TASK", args)
end

local function statsTask(args)
	local counters = {}
	for i, v in ipairs(args.devices) do
		table.insert(args.rxDevices, v)
		table.insert(args.txDevices, v)
	end
	for i, dev in ipairs(args.rxDevices) do
		table.insert(counters, mod:newDevRxCounter(dev, args.format, args.file))
	end
	for i, dev in ipairs(args.txDevices) do
		table.insert(counters, mod:newDevTxCounter(dev, args.format, args.file))
	end
	while phobos.running() do
		for i, ctr in ipairs(counters) do
			ctr:update()
		end
		phobos.sleepMillisIdle(100)
	end
	for i, ctr in ipairs(counters) do
		ctr:finalize()
	end
end

__PHOBOS_STATS_TASK = statsTask

return mod

