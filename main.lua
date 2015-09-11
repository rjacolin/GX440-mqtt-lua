-------------------------------------------------------------------------------
-- Copyright (c) 2012, 2013 Sierra Wireless and others.
-- All rights reserved. This program and the accompanying materials
-- are made available under the terms of the Eclipse Public License v1.0
-- which accompanies this distribution, and is available at
-- http://www.eclipse.org/legal/epl-v10.html
--
-- Contributors:
--     Benjamin Cabé, Sierra Wireless - initial API and implementation
--     Gaétan Morice, Sierra Wireless - initial API and implementation
-------------------------------------------------------------------------------

-- ----------------------------------------------------------------------------
-- REQUIRES
-- ----------------------------------------------------------------------------

local sched  = require 'sched'
local modbus = require 'modbus'
local mqtt   = require 'mqtt_library'
local utils  = require 'utils'
local tableutils = require "utils.table"
local log    = require 'log'

-- ----------------------------------------------------------------------------
-- CONSTANTS
-- ----------------------------------------------------------------------------

local ASSET_NAME        = "machine"
local MQTT_DATA_PATH    = "00000000B6AF4A9D/messages/json"
local MQTT_COMMAND_PATH = "00000000B6AF4A9D/tasks/json"
local MQTT_ACK_PATH     = "00000000B6AF4A9D/acks/json"
local MQTT_BROKER       = "eu.m2mop.net"
local MQTT_PORT         = 1883

--local MODBUS_PORT = "/dev/ttyS0"     -- serial port on AirLink GX400
local MODBUS_PORT = "/dev/ttyACM0" -- serial port on RaspPi
local MODBUS_CONF = {baudRate = 9600 }

local LOG_NAME = "MODBUS_APP"

-- ----------------------------------------------------------------------------
-- ENVIRONMENT VARIABLES
-- ----------------------------------------------------------------------------

local modbus_client
local modbus_client_pending_init = false

local mqtt_client

-- ----------------------------------------------------------------------------
-- DATA
-- ----------------------------------------------------------------------------

local modbus_address =
{luminosity  = 1,
 humidity    = 2,
 temperature = 3,
 light       = 6}

local modbus_process =
{temperature = utils.processTemperature,
 humidity    = utils.processHumidity,
 luminosity  = utils.processLuminosity}

setmetatable(modbus_process,
             {__index = function (_, _) return utils.identity end})

-- ----------------------------------------------------------------------------
-- PROCESSES
-- ----------------------------------------------------------------------------

local function init_modbus()
    if modbus_client_pending_init then return; end
    modbus_client_pending_init = true
	if modbus_client then modbus_client:close(); end
	sched.wait(1)
	modbus_client = modbus.new(MODBUS_PORT, MODBUS_CONF)
	sched.wait(1)
	log(LOG_NAME, "INFO", "Modbus client re-init'ed")
	modbus_client_pending_init = false
end

local function process_modbus ()
	if not modbus_client then
		init_modbus()
		if not modbus_client then return; end
	end

	local values = modbus_client:readHoldingRegisters(1,0,9)

	if not values then
		log(LOG_NAME, "ERROR", "Unable to read modbus")
		init_modbus()
	return end

	local val
	local buffer = {}

	buffer.timestamp=os.time()
--	for data, address in pairs(modbus_address) do
--		val = utils.convertRegister(values, address)
--		val = modbus_process[data](val)
--		log(LOG_NAME, "INFO", "Read data %s : %i", data, val)
--		-- mqtt_client:publish(MQTT_DATA_PATH..data, val)
--		mqtt_client:publish(MQTT_DATA_PATH, "{\""..data.."\":"..val.."}")
--		buffer[data] = val
--	end
	local payload=""
	for data, address in pairs(modbus_address) do
		val = utils.convertRegister(values, address)
		val = modbus_process[data](val)
		if payload == "" then
			payload= '{"'..ASSET_NAME..'.'..data..'":'..val
		else
			payload= payload..', "'..ASSET_NAME..'.'..data..'":'..val..''
		end
		log(LOG_NAME, "INFO", "Read data %s : %i", data, val)
		buffer[data] = val
	end
	log(LOG_NAME, "INFO", "Sending data %s", payload.."}")
	mqtt_client:publish(MQTT_DATA_PATH, payload.."}")
end

local function ack(ticketId)
	local payload=""
	payload = '[{"uid": "'..ticketId..'", "status" : "OK"}]'
	-- payload = '[{"uid": "'..ticketId..'", "status" : "KO", "message" : "'..msg..'"}]'
	log(LOG_NAME, "INFO", "Ack %s", payload)
	mqtt_client:publish(MQTT_ACK_PATH, payload)
end

local function process_mqtt(topic, val)
	local data = utils.split(topic, "/")[4]
	log(LOG_NAME, "INFO", "Receive mqtt %s : %i", data, val)
	modbus_client:writeMultipleRegisters(1, modbus_address[data], string.pack("h", val))
	--ack(ticketId)
end
-- ---
-- Log configuration
-- ---

local logfile  = io.open("/var/log/greenhouse", "a")
logfile:write("\n");

-- function name is important :)
function log.displaylogger(mod, level, msg)
	logfile:write(msg.."\n")
	logfile:flush()
end

-- ----------------------------------------------------------------------------
-- MAIN
-- ----------------------------------------------------------------------------
local function main()
	log.setlevel("INFO")
	log(LOG_NAME, "INFO", "Application started")

	modbus_client = modbus.new(MODBUS_PORT, MODBUS_CONF)
	log(LOG_NAME, "INFO", "Modbus      - OK")

	mqtt_client = mqtt.client.create(MQTT_BROKER, MQTT_PORT, process_mqtt)
	log(LOG_NAME, "INFO", "MQTT Client - OK")
	mqtt_client:connect(LOG_NAME, nil, nil, nil, nil, "00000000B6AF4A9D", "toto")
	mqtt_client:subscribe({MQTT_COMMAND_PATH.."#"})

	log(LOG_NAME, "INFO", "Init done")

	sched.wait(2)
	while true do
		process_modbus()
		mqtt_client:handler()
		sched.wait(60)
	end
end
sched.run(main)
sched.loop()
