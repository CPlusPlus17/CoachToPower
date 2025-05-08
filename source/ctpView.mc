import Toybox.Activity;
import Toybox.Lang;
import Toybox.Time;
import Toybox.WatchUi;
import Toybox.UserProfile;
import Toybox.Graphics;
import Toybox.WatchUi;
import Toybox.Math;

// Helper class to store HR and Power boundaries for a zone
class ZoneBoundaries {
    var hrMin as Number;
    var hrMax as Number;
    var wMin as Long;
    var wMax as Long;

    function initialize(hrMin as Number, hrMax as Number, wMin as Long, wMax as Long) {
        self.hrMin = hrMin;
        self.hrMax = hrMax;
        self.wMin = wMin;
        self.wMax = wMax;
    }
}

class ctpView extends WatchUi.SimpleDataField {

    // Constants for HR Zone Array Indices from UserProfile.getHeartRateZones()
    // [minZ1, maxZ1, maxZ2, maxZ3, maxZ4, maxZ5]
    private const IDX_HR_MIN_Z1 = 0;
    private const IDX_HR_MAX_Z1 = 1;

    var profile = UserProfile.getProfile();

    // Member variables
    var mThresholdPower as Number?;
    var mPZMinPercents as Array<Number>; // Stores [Z1MinP, Z1MaxP, Z2MaxP, Z3MaxP, Z4MaxP, Z5MaxP]
    var mZoneBoundariesArray as Array<ZoneBoundaries>?; // Stores combined HR and Power boundaries

    // For 5-second rolling average power
    var mPowerSamples as Array<Number>; // Array to store power samples, can hold nulls
    var mPowerSampleIndex as Number;
    var m5sAvgPower as Long?; // Changed to Long? to match .toLong()
    var POWER_SAMPLE_COUNT = 5; // For 5-second average

    function initialize() {
        SimpleDataField.initialize();
        label = "Target-Watt";

        // Load new power zone settings
        mThresholdPower = Toybox.Application.Properties.getValue("thresholdPower") as Number?;

        var pz1MinPercent = Toybox.Application.Properties.getValue("powerZone1MinPercent") as Number?;
        var pz1MaxPercent = Toybox.Application.Properties.getValue("powerZone1MaxPercent") as Number?;
        var pz2MaxPercent = Toybox.Application.Properties.getValue("powerZone2MaxPercent") as Number?;
        var pz3MaxPercent = Toybox.Application.Properties.getValue("powerZone3MaxPercent") as Number?;
        var pz4MaxPercent = Toybox.Application.Properties.getValue("powerZone4MaxPercent") as Number?;
        var pz5MaxPercent = Toybox.Application.Properties.getValue("powerZone5MaxPercent") as Number?;

        // Provide defaults if settings are not found (though they are required in settings.xml)
        // Defaults from properties.xml will be used if available, these are fallbacks for older versions or issues
        if (mThresholdPower == null || mThresholdPower <= 0) { mThresholdPower = 348; } // Updated Default FTP

        var defaultPz1Min = (pz1MinPercent == null) ? 0 : pz1MinPercent;
        var defaultPz1Max = (pz1MaxPercent == null) ? 55 : pz1MaxPercent;
        var defaultPz2Max = (pz2MaxPercent == null) ? 75 : pz2MaxPercent;
        var defaultPz3Max = (pz3MaxPercent == null) ? 90 : pz3MaxPercent;
        var defaultPz4Max = (pz4MaxPercent == null) ? 105 : pz4MaxPercent;
        var defaultPz5Max = (pz5MaxPercent == null) ? 120 : pz5MaxPercent;

        mPZMinPercents = [defaultPz1Min, defaultPz1Max, defaultPz2Max, defaultPz3Max, defaultPz4Max, defaultPz5Max];

        // Calculate Power Zones first
        var calculatedPowerZones = _calculatePowerZoneWattages(); // This now returns Array<Dictionary> or null

        // Load HR zones from UserProfile
        var deviceSportHrZones = UserProfile.getHeartRateZones(UserProfile.getCurrentSport());
        if (deviceSportHrZones != null && deviceSportHrZones.size() >= 6) {
            System.println("ctpView: initialize - Loaded HR Zones (SPORT_RUNNING): " + deviceSportHrZones.toString());
        } else {
            System.println("ctpView: initialize - Failed to load/validate SPORT_RUNNING HR Zones. Found: " + (deviceSportHrZones == null ? "null" : deviceSportHrZones.toString()));
            deviceSportHrZones = null; 
        }

        // Combine into mZoneBoundariesArray
        if (calculatedPowerZones != null && deviceSportHrZones != null) {
            mZoneBoundariesArray = new Array<ZoneBoundaries>[5];
            // HR Zones: [minZ1, maxZ1, maxZ2, maxZ3, maxZ4, maxZ5]
            // Power Zones: Array of 5 Dictionaries {"low", "high"}
            
            // Zone 1
            mZoneBoundariesArray[0] = new ZoneBoundaries(
                deviceSportHrZones[IDX_HR_MIN_Z1], deviceSportHrZones[IDX_HR_MAX_Z1],
                calculatedPowerZones[0]["low"], calculatedPowerZones[0]["high"]
            );
            // Zones 2-5
            for (var i = 1; i < 5; i++) {
                mZoneBoundariesArray[i] = new ZoneBoundaries(
                    deviceSportHrZones[i], // This is previous zone's max + 1 effectively for min
                    deviceSportHrZones[i+1], // This is current zone's max
                    calculatedPowerZones[i]["low"], calculatedPowerZones[i]["high"]
                );
            }
             System.println("ctpView: initialize - Successfully created mZoneBoundariesArray.");
        } else {
            mZoneBoundariesArray = null;
            System.println("ctpView: initialize - Failed to create mZoneBoundariesArray due to missing power or HR zones.");
        }

        // Initialize power sample array and index
        mPowerSamples = new Array<Number>[POWER_SAMPLE_COUNT];
        mPowerSampleIndex = 0;

        System.println("ctpView: initialize - Using Threshold Power: " + mThresholdPower);
        System.println("ctpView: initialize - Using PZone Percents Array: " + mPZMinPercents.toString());
    }

    // Helper function to calculate and return absolute wattage zones
    private function _calculatePowerZoneWattages() as Array<Dictionary>? {
        if (mThresholdPower == null || mPZMinPercents == null || mPZMinPercents.size() < 6) {
            System.println("ctpView: _calculatePowerZoneWattages - TP or PZonePercents not loaded/invalid.");
            return null;
        }

        var tp = mThresholdPower as Number;
        var powerZones = new Array<Dictionary>[5];
        var currentLowWattage = 0.0;

        // Zone 1
        var z1LowW = (mPZMinPercents[0] / 100.0) * tp;
        var z1HighW = (mPZMinPercents[1] / 100.0) * tp;
        powerZones[0] = { "low" => Math.round(z1LowW).toLong(), "high" => Math.round(z1HighW).toLong() };
        currentLowWattage = z1HighW + 1.0; // Ensure float for next low boundary

        // Zones 2 through 5
        for (var i = 1; i < 5; i++) {
            var zoneMaxPercent = mPZMinPercents[i + 1];
            var zoneHighWattage = (zoneMaxPercent / 100.0) * tp;
            // Ensure low is not less than previous high + 1, due to rounding
            var lowWVal = Math.round(currentLowWattage).toLong();
            var highWVal = Math.round(zoneHighWattage).toLong();
            if (i > 0 && lowWVal <= powerZones[i-1]["high"]) {
                lowWVal = powerZones[i-1]["high"] + 1;
            }
            powerZones[i] = { "low" => lowWVal, "high" => highWVal };
            currentLowWattage = zoneHighWattage + 1.0; // Ensure float for next low boundary
        }
        
        System.println("ctpView: Calculated Power Zone Wattages (rounded):");
        for (var i = 0; i < powerZones.size(); i++) {
            var zone = powerZones[i];
            System.println("  Zone " + (i + 1) + ": " + zone["low"] + "W - " + zone["high"] + "W");
        }
        return powerZones;
    }

    function compute(info as Activity.Info) as Numeric or Duration or String or Null {
        // 5-Second Average Power Calculation
        var instantaneousPower = info.currentPower;

        mPowerSamples[mPowerSampleIndex] = instantaneousPower;
        mPowerSampleIndex = (mPowerSampleIndex + 1) % POWER_SAMPLE_COUNT;

        var sum = 0.0d; // Use Double for sum to maintain precision before toLong
        var count = 0;
        for (var i = 0; i < POWER_SAMPLE_COUNT; i++) {
            if (mPowerSamples[i] != null) {
                sum += mPowerSamples[i] as Number;
                count++;
            }
        }

        if (count > 0) {
            m5sAvgPower = (sum / count).toLong();
        } else {
            m5sAvgPower = null;
        }

        var powerForRangeCheck = m5sAvgPower;
        if (powerForRangeCheck == null) {
            powerForRangeCheck = instantaneousPower; // Fallback to instantaneous if 5s avg is null
            if (powerForRangeCheck == null) {
                powerForRangeCheck = info.averagePower; // Further fallback to overall average if instantaneous is also null
            }
        }
        
        var displayCurrentPower = (m5sAvgPower != null) ? m5sAvgPower : ((instantaneousPower != null) ? instantaneousPower : 0);
        
        var workoutStepInfo = Activity.getCurrentWorkoutStep();

        try {
            if (workoutStepInfo != null && workoutStepInfo.step != null) {
                var step = workoutStepInfo.step as Activity.WorkoutStep;

                if (step has :targetType) {
                    var currentTargetType = step.targetType;

                    if (currentTargetType == Activity.WORKOUT_STEP_TARGET_HEART_RATE) {
                        var rawTargetHrLow = step.targetValueLow as Number?;
                        var rawTargetHrHigh = step.targetValueHigh as Number?;

                        if (rawTargetHrLow == null || rawTargetHrHigh == null) {
                            return "E:NullHRTgt";
                        }

                        var correctedTargetHrLow = rawTargetHrLow - 100;
                        var correctedTargetHrHigh = rawTargetHrHigh - 100;
                        var midTargetHr = (correctedTargetHrLow + correctedTargetHrHigh) / 2.0;

                        if (mZoneBoundariesArray == null) {
                            // This implies either device HR zones or power zones couldn't be initialized
                            return WatchUi.loadResource(Rez.Strings.ErrorNoDeviceHRZones) as String; 
                        }

                        var matchedZone = null as ZoneBoundaries?;
                        for (var i = 0; i < mZoneBoundariesArray.size(); i++) {
                            var currentZone = mZoneBoundariesArray[i];
                            if (midTargetHr >= currentZone.hrMin && midTargetHr <= currentZone.hrMax) {
                                matchedZone = currentZone;
                                break;
                            }
                        }

                        if (matchedZone == null) {
                            // If HR target is below Zone 1 min or (for some reason) above Zone 5 max as defined by device
                            // Check if it's above Z5 max specifically, as Z5 is often open-ended upwards.
                            // The deviceSportHrZones array has IDX_HR_MAX_Z5.
                            // If midTargetHr > mZoneBoundariesArray[4].hrMax (which is device's Z5 max), it's still Z5.
                            // This case should ideally be caught by the loop if Z5 max is very high.
                            // Let's refine the loop for Z5 to be open-ended from Z4 max.
                            // The ZoneBoundaries for Z5 will have hrMax as deviceSportHrZones[IDX_HR_MAX_Z5].
                            // If midTargetHr > mZoneBoundariesArray[3].hrMax (i.e. > Z4 max) it could be Z5.
                            // The current loop structure should handle this if Z5 max is set appropriately by device.
                            // If no zone is matched after loop, it means HR is outside all defined ranges.
                            return WatchUi.loadResource(Rez.Strings.ErrorHrOutOfZoneRange) as String;
                        }
                        
                        var lowW = matchedZone.wMin;
                        var highW = matchedZone.wMax;
                        var prefix = "";

                        if (powerForRangeCheck != null && lowW != null && highW != null && powerForRangeCheck >= lowW && powerForRangeCheck <= highW) {
                            prefix = "🟢 ";
                        } else {
                            prefix = "🔴 ";
                        }
                        return prefix + displayCurrentPower.format("%d") + "W (" + lowW.format("%d") + "-" + highW.format("%d") + ")";
                        
                    } else if (currentTargetType == Activity.WORKOUT_STEP_TARGET_POWER) {
                        var powerLowTarget = step.targetValueLow as Number;
                        var powerHighTarget = step.targetValueHigh as Number;
                        var prefix = "";

                        if (powerForRangeCheck != null && powerLowTarget != null && powerHighTarget != null && powerForRangeCheck >= powerLowTarget && powerForRangeCheck <= powerHighTarget) {
                            prefix = "🟢 ";
                        } else {
                            prefix = "🔴 ";
                        }
                        return prefix + displayCurrentPower.format("%d") + "W (" + powerLowTarget.format("%d") + "-" + powerHighTarget.format("%d") + ")";
                    }
                    else { 
                        return "E:TgtTypeUnk";
                    }
                } else { 
                    return "E:NoTgtType";
                }
            } else { 
                return "E:NoWorkStepInfo";
            }
        } catch (ex instanceof Lang.Exception) {
            System.println("ctpView: compute - EXCEPTION: " + ex.getErrorMessage());
            var errorMsg = ex.getErrorMessage();
            if (errorMsg != null) {
                if (errorMsg.length() > 20) { 
                    errorMsg = errorMsg.substring(0, 20);
                }
            } else {
                errorMsg = "ErrNull";
            }
            return "E:" + errorMsg;
        }
    }
}
