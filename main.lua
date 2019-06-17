-- ESP8266 TCP DS18B20 SIM800L

local M = {}

console = require("tcp-console-log")
comrade = require("comrade")
router = require("router")

local simIsFree = true
local simTimer = tmr.create()
local secTimer = tmr.create()
local busyTimer = tmr.create()
local readTimer = tmr.create()
local athTimer = tmr.create()
local cmgsTimer = tmr.create()
-- local cmgdTimer = tmr.create()
local measureTimer = tmr.create()
local measureInterval = 30000 -- in milliseconds
      
local ds = { 
  addr = string.char(0x28, 0xA1, 0xBD, 0x53, 0x03, 0x00, 0x00, 0x62),
  temp = 1360, -- 1360 0x0550 85 C   
  tick = 0,
  pin = 4 -- gpio0 = 3, gpio2 = 4
}

local function readTemperature()
  ow.reset(ds.pin)
  ow.select(ds.pin, ds.addr)
  ow.write(ds.pin, 0x44, 0)
  readTimer:alarm(760, tmr.ALARM_SINGLE, function ()
    ow.reset(ds.pin)
    ow.select(ds.pin, ds.addr)
    ow.write(ds.pin, 0xBE, 0)
    local data = ow.read_bytes(ds.pin, 9)
    local crc = ow.crc8(string.sub(data,1,8))
    if crc == data:byte(9) then
      ds.temp = data:byte(1) + data:byte(2) * 256  -- t Centigrade * 16
      ds.tick = tmr.time() -- system uptime in seconds, 31 bits
      local nh = tostring (node.heap())
      console.put('ds.temp: '..ds.temp..' ds.tick: '..ds.tick..' node.heap: '..nh)
    else
      ds.temp = 1360  -- 0x0550 85 C   
    end
  end)
end

local function sendReport(telNumber)
  console.put('sendReport in')
  measureTimer:unregister()

  athTimer:alarm(5000, tmr.ALARM_SINGLE, function ()
    uart.write(0, 'ATH\r')
    console.put('sendReport: ATH\r')
    cmgsTimer:alarm(5000, tmr.ALARM_SINGLE, function ()
      uart.write(0, 'AT+CMGS="'..telNumber..'"\r')
      console.put('sendReport: AT+CMGS="'..telNumber..'"\r')
      secTimer:alarm(1000, tmr.ALARM_SINGLE, function ()
        local tA = ds.temp * 625
        local tI = tA / 10000
        local tF = (tA%10000)/1000 + ((tA%1000)/100 >= 5 and 1 or 0)
        local report = string.format("test t = %d.%d C\r\n", tI, tF)
        console.put('sendReport: '..report)
        uart.write(0, report)
        uart.write(0, '\26') -- CTRL_Z
        -- uart.write(0, '\r')
--[[
        cmgdTimer:alarm(5000, tmr.ALARM_SINGLE, function ()
          uart.write(0, 'AT+CMGD=1,4') -- удалить все СМС
        end)
]]
  
        measureTimer:register(measureInterval, tmr.ALARM_AUTO, readTemperature)
        measureTimer:start()
      end)
    end)
  end)
end

function M.start()
  -- register callback function, when '\n' is received.
  uart.on("data", "\n",
    function(data)
      if simIsFree then console.put('simIsFree == true')
      else console.put('simIsFree == false') end
      console.put('from sim: '..data)
      if simIsFree and string.sub(data,1,6) == "+CLIP:" then
        simIsFree = false
        busyTimer:alarm(60000, tmr.ALARM_SINGLE, function () simIsFree = true end)
        -- при входящем вызове модем SIM800L выдает раз в секунду строки
        -- RING
        -- +CLIP: "+7XXXXXXXXXX",145,"",0,"",0
        local callerNumber
        local comradeNumber
        _, _, callerNumber = string.find(data, '%+CLIP: "(%+%d+)"')
        for _, comradeNumber in ipairs(comrade) do
          if comradeNumber == callerNumber then 
            console.put('telNumber: '..comradeNumber)
            sendReport(comradeNumber)
            break
          end
        end
      end
    end, 0
  )
  uart.setup(0, 115200, 8, uart.PARITY_NONE, uart.STOPBITS_1, 0)
  --uart.setup(0, 9600, 8, uart.PARITY_NONE, uart.STOPBITS_1, 0)

  -- configure ESP as a station
  wifi.setmode(wifi.STATION, false)
  -- соединяемся с точкой доступа
  wifi.eventmon.register(wifi.eventmon.STA_GOT_IP, 
    function(T)
      console.put("\nSTA - GOT IP"..
        "\nStation IP: "..T.IP..
        "\nSubnet mask: "..T.netmask..
        "\nGateway IP: "..T.gateway)
      console.init()
      local i = 0
      simTimer:register(2000, tmr.ALARM_AUTO,
        function(t) 
          i = i + 1
          if i > 3 then 
            t:unregister()
            uart.write(0, 'AT+CLIP=1\r')
          else
            uart.write(0, 'AT\r')
          end
        end
      )
      simTimer:start()
    end
  )
  wifi.sta.config({ssid = router.ssid, pwd  = router.pwd, save = false})
  
  ow.setup(ds.pin)
  measureTimer:register(measureInterval, tmr.ALARM_AUTO, readTemperature)
  measureTimer:start()
end

return M
