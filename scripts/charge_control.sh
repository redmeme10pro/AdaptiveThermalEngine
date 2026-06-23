#!/system/bin/sh
# ThermalAI - Charge Heat Control
# Dynamically adjusts maximum charging current to prevent the phone from overheating
# while plugged in.

# Charging paths (qualcomm standard)
BATT_CURRENT_MAX="/sys/class/power_supply/battery/constant_charge_current_max"
BATT_CURRENT_NOW="/sys/class/power_supply/battery/current_now"

# Set limits in microamps (uA)
# 3000mA = 3000000 uA
# 2000mA = 2000000 uA
# 1000mA = 1000000 uA
# 500mA  = 500000 uA

# Battery Paths
BATT_CAPACITY="/sys/class/power_supply/battery/capacity"

# ─── Robust Battery Temp Read ─────────────────────────────────────────────────
get_robust_battery_temp() {
    local batt_temp=0

    # Best reliable path on most Android devices
    local primary_path="/sys/class/power_supply/battery/temp"

    if [ -f "$primary_path" ]; then
        batt_temp=$(cat "$primary_path" 2>/dev/null || echo 0)
        [ "$batt_temp" -gt 10000 ] && batt_temp=$((batt_temp / 100))
        if [ "$batt_temp" -ge 100 ] && [ "$batt_temp" -le 800 ]; then
            echo "$batt_temp"
            return
        fi
    fi

    # Fallback to dynamic thermal zones
    # We want MIN of matched to avoid charger_therm inflating actual battery temp
    local min_t=999
    local found_exact_battery="false"

    for tz_type in /sys/class/thermal/thermal_zone*/type; do
        [ -f "$tz_type" ] || continue
        local type_val=$(cat "$tz_type" 2>/dev/null | tr -d '\n')

        # If we find EXACTLY "battery", take it and exit loop.
        if [ "$type_val" = "battery" ]; then
            local tz_dir="${tz_type%/*}"
            if [ -f "$tz_dir/temp" ]; then
                local raw=$(cat "$tz_dir/temp" 2>/dev/null || echo 0)
                [ "$raw" -gt 10000 ] && raw=$((raw / 100))
                if [ "$raw" -ge 100 ] && [ "$raw" -le 800 ]; then
                    echo "$raw"
                    return
                fi
            fi
        fi

        # Otherwise, collect matches and find the minimum valid one
        if echo "$type_val" | grep -iqE "battery|charger_therm|vbat"; then
            local tz_dir="${tz_type%/*}"
            if [ -f "$tz_dir/temp" ]; then
                local raw=$(cat "$tz_dir/temp" 2>/dev/null || echo 0)
                [ "$raw" -gt 10000 ] && raw=$((raw / 100))
                if [ "$raw" -ge 100 ] && [ "$raw" -le 800 ]; then
                    if [ "$raw" -lt "$min_t" ]; then
                        min_t="$raw"
                    fi
                fi
            fi
        fi
    done

    if [ "$min_t" -lt 999 ]; then
        echo "$min_t"
    else
        # Safe default
        echo 350
    fi
}

# ─── Adjust Charging Current ──────────────────────────────────────────────────
# Global Adaptive Charging Variables
ADAPTIVE_CHARGE_CURRENT_UA=5000000
ADAPTIVE_LAST_EVAL_TIME=0
ADAPTIVE_LAST_BATT_LEVEL=0
ADAPTIVE_LAST_BATT_TEMP=0

apply_charging_control() {
    local realtime_gaming="$1"  # Unlatched true/false indicating instant game status
    local screen_state
    screen_state=$(cat /sys/class/backlight/panel0-backlight/brightness 2>/dev/null || echo "100")
    local is_screen_on="true"
    if [ "$screen_state" = "0" ]; then
        is_screen_on="false"
    fi

    # Read actual battery temperature safely
    local batt_temp_raw
    batt_temp_raw=$(get_robust_battery_temp)
    local batt_temp=$((batt_temp_raw / 10))

    local current_plugged=$(cat /sys/class/power_supply/battery/status 2>/dev/null || echo "Unknown")

    # Read battery capacity / SOC percentage
    local batt_level=0
    if [ -f "$BATT_CAPACITY" ]; then
        batt_level=$(cat "$BATT_CAPACITY" 2>/dev/null || echo 0)
    fi

    # Only enforce limits if the device is actually charging
    if [ "$current_plugged" != "Charging" ]; then
        LAST_APPLIED_CHARGE_LIMIT=""
        return 0
    fi

    # Initialize adaptive tracking if needed
    local current_time
    current_time=$(date +%s)
    if [ "$ADAPTIVE_LAST_EVAL_TIME" -eq 0 ]; then
        ADAPTIVE_LAST_EVAL_TIME="$current_time"
        ADAPTIVE_LAST_BATT_LEVEL="$batt_level"
        ADAPTIVE_LAST_BATT_TEMP="$batt_temp"
        ADAPTIVE_CHARGE_CURRENT_UA=5000000
    fi

    # 1. Adaptive AI Charging Logic (runs every 60 seconds)
    local elapsed=$((current_time - ADAPTIVE_LAST_EVAL_TIME))
    if [ "$elapsed" -ge 60 ]; then
        local level_gained=$((batt_level - ADAPTIVE_LAST_BATT_LEVEL))
        local temp_diff=$((batt_temp - ADAPTIVE_LAST_BATT_TEMP))

        # Determine the target temperature based on context
        local target_temp=38
        if [ "$realtime_gaming" = "true" ]; then
            target_temp=36
        fi

        # Adaptive adjustments based on learning (temp_diff)
        if [ "$batt_temp" -gt "$target_temp" ]; then
            if [ "$temp_diff" -gt 0 ]; then
                # Rising temp: reduce aggressively
                ADAPTIVE_CHARGE_CURRENT_UA=$((ADAPTIVE_CHARGE_CURRENT_UA - 500000))
            else
                # Temp is high but stable/dropping: reduce slightly
                ADAPTIVE_CHARGE_CURRENT_UA=$((ADAPTIVE_CHARGE_CURRENT_UA - 250000))
            fi
        elif [ "$batt_temp" -lt "$((target_temp - 2))" ]; then
            # We are cool, can increase current
            if [ "$temp_diff" -lt 0 ]; then
               # Temp dropping, safe to increase more
               ADAPTIVE_CHARGE_CURRENT_UA=$((ADAPTIVE_CHARGE_CURRENT_UA + 500000))
            else
               # Stable temp, increase slowly
               ADAPTIVE_CHARGE_CURRENT_UA=$((ADAPTIVE_CHARGE_CURRENT_UA + 250000))
            fi
        fi

        # Update tracking variables
        ADAPTIVE_LAST_EVAL_TIME="$current_time"
        ADAPTIVE_LAST_BATT_LEVEL="$batt_level"
        ADAPTIVE_LAST_BATT_TEMP="$batt_temp"
    fi

    # 2. Hard Limits & Boundaries
    # Absolute maximum is 5A
    if [ "$ADAPTIVE_CHARGE_CURRENT_UA" -gt 5000000 ]; then
        ADAPTIVE_CHARGE_CURRENT_UA=5000000
    fi

    # Absolute minimum is 500mA to prevent battery drain while plugged in
    if [ "$ADAPTIVE_CHARGE_CURRENT_UA" -lt 500000 ]; then
        ADAPTIVE_CHARGE_CURRENT_UA=500000
    fi

    # Emergency thermal override
    if [ "$batt_temp" -ge 40 ]; then
        ADAPTIVE_CHARGE_CURRENT_UA=500000
    fi

    local max_current_ua="$ADAPTIVE_CHARGE_CURRENT_UA"

    # 3. PMIC Starvation Protection (Screen On)
    # If the screen is on and we are not in emergency thermal state (>40C),
    # never drop below 1.5A to ensure the UI stays smooth and PMIC doesn't throttle CPU/GPU.
    if [ "$is_screen_on" = "true" ] && [ "$batt_temp" -lt 40 ]; then
        if [ "$max_current_ua" -lt 1500000 ]; then
            max_current_ua=1500000
        fi
    fi

    # 4. Apply SOC-based graceful degradation overriding everything except emergency limits
    if [ "$batt_level" -ge 90 ] && [ "$max_current_ua" -gt 1000000 ]; then
        max_current_ua="1000000"
    fi

    # 5. Hardware Enforcement
    if [ "$LAST_APPLIED_CHARGE_LIMIT" != "$max_current_ua" ]; then
        if [ -w "$BATT_CURRENT_MAX" ]; then
            sysfs_write "$max_current_ua" "$BATT_CURRENT_MAX"
        fi
        apply_universal_charging_control "$max_current_ua"

        echo "[$(date "+%Y-%m-%d %H:%M:%S")] [DEBUG] Adaptive charge limit set to $((max_current_ua / 1000))mA (batt_temp=${batt_temp}°C)" >> /data/local/tmp/thermalai_verbose.log 2>/dev/null

        if [ "$max_current_ua" = "5000000" ]; then
            log_info "Adaptive charging limit released to 5A (batt_temp=${batt_temp}°C)"
        else
            log_info "Adaptive charging limit adjusted to $((max_current_ua / 1000))mA (batt_temp=${batt_temp}°C)"
        fi

        LAST_APPLIED_CHARGE_LIMIT="$max_current_ua"
    else
        # Prevent hardware resetting it under our nose without spamming log
        if [ -w "$BATT_CURRENT_MAX" ]; then
            sysfs_write "$max_current_ua" "$BATT_CURRENT_MAX"
        fi
        apply_universal_charging_control "$max_current_ua"
    fi
}

# ─── Restore Charging Control ──────────────────────────────────────────────────
restore_charging_control() {
    # Qualcomm standard for "unlimited" or hardware max is usually very high or 0
    # Writing 5000000 (5A) usually restores full speed
    if [ -w "$BATT_CURRENT_MAX" ]; then
         echo "5000000" > "$BATT_CURRENT_MAX" 2>/dev/null
         log_info "Charging limits restored to hardware default"
    fi
    apply_universal_charging_control "5000000"
}

# ─── Universal Charging Control Fallbacks ─────────────────────────────────────
# Since node paths differ greatly between custom ROMs and kernels (e.g., Mediatek,
# Exynos, custom Qualcomm trees), we maintain an array of common limits.

CHARGE_NODES="
/sys/class/power_supply/battery/constant_charge_current_max
/sys/class/power_supply/battery/constant_charge_current
/sys/class/power_supply/main/constant_charge_current_max
/sys/class/qcom-battery/restricted_current
/sys/devices/virtual/power_supply/battery/current_max
/sys/class/power_supply/battery/step_charging_current
/sys/class/power_supply/bms/constant_charge_current_max
/sys/class/power_supply/usb/input_current_limit
/sys/class/power_supply/usb/current_max
/sys/class/power_supply/wireless/input_current_limit
/sys/devices/platform/soc/soc:qcom,pmic_glink/soc:qcom,pmic_glink:qcom,battery_charger/power_supply/battery/constant_charge_current
"

apply_universal_charging_control() {
    local target_ua="$1"
    local applied="false"

    for node in $CHARGE_NODES; do
        if [ -w "$node" ]; then
             sysfs_write "$target_ua" "$node"
             applied="true"
        fi
    done

    # Dynamic search for any other power_supply nodes with input_current_limit or constant_charge_current
    for dyn_node in /sys/class/power_supply/*/input_current_limit /sys/class/power_supply/*/constant_charge_current; do
        if [ -w "$dyn_node" ]; then
            sysfs_write "$target_ua" "$dyn_node"
            applied="true"
        fi
    done

    if [ "$applied" = "false" ]; then
        log_debug "No compatible fast-charging control node found on this kernel."
    fi
}
