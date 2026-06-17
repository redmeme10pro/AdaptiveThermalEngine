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

# ─── Adjust Charging Current ──────────────────────────────────────────────────
apply_charging_control() {
    local policy="$1"
    local temp="$2"
    local max_current_ua="0" # 0 means disabled / let hardware decide

    if [ ! -w "$BATT_CURRENT_MAX" ]; then
        return 0
    fi

    case "$policy" in
        suspend)
            # When screen is off, allow full speed charging if not hot
            if [ "$temp" -gt 60 ]; then
                max_current_ua="1000000" # Still hot, throttle
            elif [ "$temp" -gt 50 ]; then
                max_current_ua="2000000" # Warm, moderate
            else
                max_current_ua="3000000" # Cool, full speed
            fi
            ;;
        performance)
            # High performance requested, moderate limit to prevent compounded heat
            max_current_ua="2500000"
            ;;
        balanced)
            # Normal usage, slightly lower limit
            max_current_ua="2000000"
            ;;
        conservative)
            # Phone is getting warm
            max_current_ua="1500000"
            ;;
        powersave)
            # Phone is hot, slow charging down significantly
            max_current_ua="1000000"
            ;;
        emergency_cool)
            # Phone is critically hot, trickle charge only
            max_current_ua="500000"
            ;;
        *)
            max_current_ua="2000000"
            ;;
    esac

    # Ensure we don't accidentally completely disable charging unless intended
    if [ "$max_current_ua" != "0" ]; then
        echo "$max_current_ua" > "$BATT_CURRENT_MAX" 2>/dev/null
        log_debug "Charging current limit set to $((max_current_ua / 1000))mA (policy=$policy)"
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
}
