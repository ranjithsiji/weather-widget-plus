/*
 * Copyright 2015  Martin Kotelnik <clearmartin@seznam.cz>
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation; either version 2 of
 * the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http: //www.gnu.org/licenses/>.
 */
import QtQuick
import "../../code/model-utils.js" as ModelUtils
import "../../code/data-loader.js" as DataLoader
import "../../code/unit-utils.js" as UnitUtils

Item {
    id: owm

    property string providerId: 'owm'
    property string urlPrefix: 'https://api.openweathermap.org/data/2.5'
    property string appIdSuffix: '&units=metric&appid=5819a34c58f8f07bc282820ca08948f1'

    function parseISOString(s) {
        var b = s.split(/\D+/)
        return new Date(Date.UTC(b[0], --b[1], b[2], b[3], b[4], b[5], b[6]))
    }

    function loadDataFromInternet(successCallback, failureCallback, locationObject) {
        dbgprint2("OWM loadDataFromInternet")

        var placeIdentifier = locationObject.placeIdentifier
        var versionParam = '&v=' + new Date().getTime()

        var url1, url3
        if (!useOnlineWeatherData) {
            url1 = Qt.resolvedUrl('../../code/weather/current.' + placeIdentifier + '.json')
            url3 = Qt.resolvedUrl('../../code/weather/forecast.' + placeIdentifier + '.json')
        } else {
            url1 = urlPrefix + '/weather?id=' + placeIdentifier + appIdSuffix + versionParam
            url3 = urlPrefix + '/forecast?id=' + placeIdentifier + appIdSuffix + versionParam
        }

        dbgprint("url1 (current): " + url1)
        dbgprint("url3 (forecast): " + url3)

        var loadedData = {
            current: null,
            hourByHour: null
        }

        function checkAndProcess() {
            if (loadedData.current === null || loadedData.hourByHour === null) {
                return
            }
            getTimeZoneName()
            updatecurrentWeather(loadedData.current, loadedData.hourByHour)
            updateNextDaysModel(loadedData.current, loadedData.hourByHour)
            buildMetogramData(loadedData.current, loadedData.hourByHour)
            loadCompleted()
        }

        var xhr1 = DataLoader.fetchJsonFromInternet(url1, function(json) {
            loadedData.current = JSON.parse(json)
            checkAndProcess()
        }, failureCallback)

        var xhr3 = DataLoader.fetchJsonFromInternet(url3, function(json) {
            loadedData.hourByHour = JSON.parse(json)
            checkAndProcess()
        }, failureCallback)

        return [xhr1, xhr3]
    }

    function updatecurrentWeather(current, hourByHour) {
        dbgprint2('updatecurrentWeather (OWM)')

        var now = new Date()
        dbgprint('now: ' + now)

        currentWeatherModel.temperature = current.main.temp
        currentWeatherModel.iconName = String(current.weather[0].id)
        currentWeatherModel.humidity = current.main.humidity
        currentWeatherModel.pressureHpa = current.main.pressure
        currentWeatherModel.windSpeedMps = current.wind.speed
        currentWeatherModel.windDirection = current.wind.deg || 0
        currentWeatherModel.cloudiness = current.clouds.all
        currentWeatherModel.updated = new Date(current.dt * 1000).toISOString().substring(0, 19)

        var futureItem = hourByHour.list[1]
        currentWeatherModel.nearFutureWeather.iconName = String(futureItem.weather[0].id)
        currentWeatherModel.nearFutureWeather.temperature = futureItem.main.temp

        let sunRise = current.sys.sunrise * 1000
        let sunSet = current.sys.sunset * 1000
        let tzms = current.timezone * 1000
        currentPlace.timezoneOffset = current.timezone
        currentWeatherModel.sunRise = new Date(sunRise)
        currentWeatherModel.sunSet = new Date(sunSet)
        currentWeatherModel.sunRiseTime = new Date(sunRise + tzms).toTimeString()
        currentWeatherModel.sunSetTime = new Date(sunSet + tzms).toTimeString()

        let updated = current.dt * 1000
        currentWeatherModel.isDay = ((updated > sunRise) && (updated < sunSet)) ? 0 : 1

        dbgprint("Updated=" + updated/1000 + "\t" + sunRise/1000 + "\t" + sunSet/1000)
        dbgprint("Updated=" + updated/1000 + "\t" + (updated > sunRise) + "\t" + (updated < sunSet))
        dbgprint(
            "Updated=" + new Date(updated).toTimeString() +
            "\t Sunrise=" + currentWeatherModel.sunRiseTime +
            "\tSunset=" + currentWeatherModel.sunSetTime + "\t" +
            ((currentWeatherModel.isDay === 0) ? "isDay\n" : "isNight\n"))

        dbgprint2('EXIT updatecurrentWeather')
    }

    function updateNextDaysModel(current, hourByHour) {
        function blankObject() {
            const myblankObject = {}
            for (let f = 0; f < 4; f++) {
                myblankObject["temperature" + f] = -999
                myblankObject["iconName" + f] = ''
                myblankObject['hidden' + f] = true
                myblankObject['partOfDay' + f] = 0
            }
            return myblankObject
        }

        dbgprint2("updateNextDaysModel")
        nextDaysModel.clear()

        let offset = 0
        switch (timezoneType) {
            case (0):
                offset = dataSource.data["Local"]["Offset"]
                break;
            case (1):
                offset = 0
                break;
            case (2):
                offset = currentPlace.timezoneOffset
                break;
        }

        let currentDtMs = current.dt * 1000
        let dataTime = new Date(currentDtMs)
        let nextDaysData = blankObject()
        let x = 0

        // Find first entry at or after current time
        let ptr = 0
        while (ptr < hourByHour.list.length && hourByHour.list[ptr].dt * 1000 < currentDtMs) {
            ptr++
        }

        dbgprint("*********************************************************************")
        dbgprint("Parsing Data starting at Row " + ptr + " of hourByHour.list")

        // Step by 2 entries (6 hours) to get one entry per 6-hour period
        while (ptr < hourByHour.list.length && x < 7) {
            let item = hourByHour.list[ptr]
            let itemDtMs = item.dt * 1000

            // Apply offset to get local time, then read UTC hours of shifted timestamp
            let localMs = itemDtMs + offset * 1000
            let hr = new Date(localMs).getUTCHours()
            let y = Math.trunc(hr / 6)

            dbgprint(new Date(localMs).toUTCString() + "\thr=" + hr + "\ty=" + y)

            nextDaysData['temperature' + y] = Math.round(item.main.temp)
            nextDaysData['iconName' + y] = String(item.weather[0].id)
            nextDaysData['hidden' + y] = false

            if (y === 3) {
                nextDaysData['dayTitle'] = composeNextDayTitle(dataTime)
                dataTime.setDate(dataTime.getDate() + 1)
                dbgprint("*** PUSHED ROW " + x + "\t" + nextDaysData['dayTitle'])
                nextDaysModel.append(nextDaysData)
                nextDaysData = blankObject()
                x++
            }

            ptr += 2
        }

        dbgprint("nextDaysModel Count:" + nextDaysModel.count)
        dbgprint2("EXIT updateNextDaysModel")
    }

    function buildMetogramData(current, hourByHour) {
        dbgprint2("buildMetogramData (OWM)" + currentPlace.identifier)

        let offset = 0
        switch (main.timezoneType) {
            case (0):
                offset = dataSource.data["Local"]["Offset"]
                break;
            case (1):
                offset = 0
                break;
            case (2):
                offset = currentPlace.timezoneOffset
                break;
        }

        dbgprint2("DEBUG:" + timezoneType + "    " + offset)
        meteogramModel.clear()

        var limitMsDifference = 1000 * 60 * 60 * 54 // 2.25 days
        var firstFromMs = null

        var sunrise1 = new Date(currentWeatherModel.sunRise)
        var sunset1 = new Date(currentWeatherModel.sunSet)
        var isDaytime = false

        for (var i = 0; i < hourByHour.list.length; i++) {
            let item = hourByHour.list[i]
            let itemDtMs = item.dt * 1000
            let itemToMs = itemDtMs + 10800000 // 3 hours later

            // Apply offset to produce "local" dates for display
            let dateFrom = new Date(convertToLocalTime(itemDtMs, offset))
            let dateTo = new Date(convertToLocalTime(itemToMs, offset))

            if (firstFromMs === null) {
                firstFromMs = dateFrom.getTime()
            }

            let localtimestamp = UnitUtils.convertDate(new Date(itemToMs), main.timezoneType, offset)
            if (localtimestamp >= sunrise1) {
                if (localtimestamp < sunset1) {
                    isDaytime = true
                } else {
                    sunrise1.setDate(sunrise1.getDate() + 1)
                    sunset1.setDate(sunset1.getDate() + 1)
                    isDaytime = false
                }
            }

            let prec = 0
            if (item.rain && item.rain['3h']) {
                prec = item.rain['3h']
            } else if (item.snow && item.snow['3h']) {
                prec = item.snow['3h']
            }

            dbgprint("DATEFROM\t" + new Date(itemDtMs).toUTCString() + "\t\t" + dateFrom)
            dbgprint("DATETO\t" + new Date(itemToMs).toUTCString() + "\t\t" + dateTo)

            meteogramModel.append({
                from: dateFrom,
                to: dateTo,
                isDaytime: isDaytime,
                temperature: parseFloat(item.main.temp),
                precipitationAvg: parseFloat(prec),
                precipitationLabel: "",
                windDirection: parseFloat(item.wind.deg || 0),
                windSpeedMps: parseFloat(item.wind.speed),
                pressureHpa: parseFloat(item.main.pressure),
                iconName: String(item.weather[0].id)
            })

            if (dateTo.getTime() - firstFromMs > limitMsDifference) {
                dbgprint('breaking')
                break
            }
        }

        dbgprint('meteogramModel.count = ' + meteogramModel.count)
    }

    function convertToLocalTime(timestampMs, timezoneOffsetSeconds) {
        return new Date(timestampMs + timezoneOffsetSeconds * 1000)
    }

    function composeNextDayTitle(date) {
        dbgprint2("composeNextDayTitle    " + date)
        return Qt.locale().dayName(date.getDay(), Locale.ShortFormat) + ' ' + date.getDate() + '/' + (date.getMonth() + 1)
    }

    function getCreditLabel(placeIdentifier) {
        return i18n("Forecast data provided by OpenWeather")
    }

    function getCreditLink(placeIdentifier) {
        return 'http://openweathermap.org/city/' + placeIdentifier
    }

    function reloadMeteogramImage(placeIdentifier) {
        main.overviewImageSource = ''
    }

    function getTimeZoneName() {
        dbgprint2("getTimeZoneName")
        switch (timezoneType) {
            case 0:
                currentPlace.timezoneShortName = getLocalTimeZone()
                break
            case 1:
                currentPlace.timezoneShortName = i18n("UTC")
                break
            case 2:
                currentPlace.timezoneShortName = getLocalTimeZone()
                break
        }
        dbgprint("timezoneName changed to:" + currentPlace.timezoneShortName)
    }

    function loadCompleted() {
        main.loadingDataComplete = true
        dataLoadedFromInternet()
    }
}
