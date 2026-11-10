#!/usr/bin/env bash
set -euo pipefail
umask 077

evidence="$RUNNER_TEMP/auraqr-16kb-evidence"
mkdir -p "$evidence"
scratch="$(mktemp -d "$RUNNER_TEMP/auraqr-16kb.XXXXXXXX")"
aab="$RUNNER_TEMP/auraqr-16kb-input/AuraQR_0.1.4_12_PRODUCTION.aab"
aab_sha=4eafa3a840dfecf8fff173fb64a0bc5eb75d77b0065e24479dcdb00ed702a245
package=com.auralabs.lectorqr
image='system-images;android-36;google_apis_ps16k;x86_64'
sdk="$ANDROID_HOME"
adb="$sdk/platform-tools/adb"
serial=emulator-5580
emulator_pid=''
stage=preflight
exec 3>&1
exec > "$scratch/private.log" 2>&1
device() { timeout 15s "$adb" -s "$serial" "$@"; }

finish() {
    local code=$?
    if [[ -n "$emulator_pid" ]]; then
        device emu kill >/dev/null 2>&1 || kill "$emulator_pid" 2>/dev/null || true
    fi
    printf 'stage=%s\nexit=%s\nqr=NOT_EXECUTED_HEADLESS\n' "$stage" "$code" > "$evidence/result.txt"
    printf 'Etapa %s. Código %s.\n' "$stage" "$code" >&3
    rm -rf -- "$scratch" || true
}
trap finish EXIT
fail() { printf 'STOP: %s\n' "$1" | tee -a "$evidence/checks.txt" >&3; exit 1; }
check_ram() {
    local available
    available="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"
    printf 'hostMemAvailableKiB=%s\n' "$available" >> "$evidence/checks.txt"
    [[ "$available" =~ ^[0-9]+$ && "$available" -ge 6291456 ]] || fail 'Host con menos de 6 GiB disponibles'
}

[[ -f "$aab" ]] || fail 'Falta el AAB aprobado'
printf '%s  %s\n' "$aab_sha" "$aab" | sha256sum -c -
printf '%s  AuraQR_0.1.4_12_PRODUCTION.aab\n' "$aab_sha" > "$evidence/SHA256SUMS.txt"
check_ram
cpus="$(nproc)"
printf 'hostCpu=%s\n' "$cpus" >> "$evidence/checks.txt"
(( cpus >= 4 )) || fail 'Runner con menos de 4 vCPU'
[[ -c /dev/kvm ]] || fail '/dev/kvm no disponible'
if [[ ! -r /dev/kvm || ! -w /dev/kvm ]]; then
    sudo setfacl -m "u:$(id -un):rw" /dev/kvm
fi
available_disk="$(df -Pk "$sdk" "$scratch" | awk 'NR>1 && (NR==2 || $4<min) {min=$4} END {print min}')"
[[ "$available_disk" =~ ^[0-9]+$ && "$available_disk" -ge 8388608 ]] || fail 'Menos de 8 GiB disponibles para imagen y AVD'

stage=emulator_setup
sdkmanager="$sdk/cmdline-tools/latest/bin/sdkmanager"
build_tools="$(jq -er .android.verification_build_tools toolchain.json)"
apksigner="$sdk/build-tools/$build_tools/apksigner"
[[ -x "$sdkmanager" ]] || fail 'Falta SDK Manager en el runner'
if [[ ! -x "$sdk/emulator/emulator" ]]; then
    "$sdkmanager" --sdk_root="$sdk" --install emulator
fi
if [[ ! -x "$adb" ]]; then
    "$sdkmanager" --sdk_root="$sdk" --install platform-tools
fi
if [[ ! -x "$apksigner" ]]; then
    "$sdkmanager" --sdk_root="$sdk" --install "build-tools;$build_tools"
fi
[[ -x "$sdk/emulator/emulator" && -x "$adb" && -x "$apksigner" ]] || fail 'SDK Android incompleto'
"$sdk/emulator/emulator" -accel-check > "$scratch/acceleration.txt"
grep -qx '0' "$scratch/acceleration.txt" || fail 'Aceleración KVM no acreditada'
printf 'kvm=PASS\n' >> "$evidence/checks.txt"

stage=toolchain
bundletool="$scratch/bundletool.jar"
curl --fail --silent --show-error --location --proto '=https' --max-time 120 \
    "$(jq -er .bundletool.url toolchain.json)" --output "$bundletool"
bundle_sha="$(jq -er .bundletool.sha256 toolchain.json)"
printf '%s  %s\n' "$bundle_sha" "$bundletool" | sha256sum -c -
printf '%s  bundletool-1.18.3.jar\n' "$bundle_sha" >> "$evidence/SHA256SUMS.txt"
bundle() { java -Xmx512m -jar "$bundletool" "$@"; }
[[ "$(bundle version)" == 1.18.3 ]] || fail 'Versión inesperada de bundletool'
"$sdkmanager" --sdk_root="$sdk" --install "$image"
grep -E '^(Pkg.Revision|AndroidVersion.ApiLevel|SystemImage.Abi)=' \
    "$sdk/system-images/android-36/google_apis_ps16k/x86_64/source.properties" > "$evidence/image.txt"
export ANDROID_AVD_HOME="$scratch/avd"
mkdir -p "$ANDROID_AVD_HOME"
printf 'no\n' | "$sdk/cmdline-tools/latest/bin/avdmanager" create avd -n AuraQR16KB \
    -k "$image" -d pixel_6
check_ram

stage=boot
"$sdk/emulator/emulator" -avd AuraQR16KB -port 5580 -accel on -memory 4096 -cores 3 \
    -gpu swiftshader_indirect -no-window -no-snapshot -no-audio -no-boot-anim \
    -camera-back none -camera-front none > "$scratch/emulator.log" 2>&1 &
emulator_pid=$!
deadline=$((SECONDS + 480))
while [[ "$(device shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)" != 1 ]]; do
    kill -0 "$emulator_pid" 2>/dev/null && (( SECONDS < deadline )) || fail 'Android no completó el arranque'
    sleep 5
done
[[ "$(device shell getprop ro.build.version.sdk)" == 36 ]] || fail 'API distinta de 36'
[[ "$(device shell getprop ro.product.cpu.abi)" == x86_64 ]] || fail 'ABI distinta de x86_64'
[[ "$(device shell getconf PAGE_SIZE)" == 16384 ]] || fail 'PAGE_SIZE distinto de 16384'
printf 'api=36\nabi=x86_64\npageSize=16384\nfingerprint=%s\n' \
    "$(device shell getprop ro.build.fingerprint)" >> "$evidence/checks.txt"

check_incidents() {
    device logcat -b events -d -v brief -s am_anr am_crash am_kill > "$scratch/events.log"
    local count
    count="$(grep -Eic '(am_anr|am_crash).*com\.(android\.systemui|auralabs\.lectorqr)|am_kill.*com\.(android\.systemui|auralabs\.lectorqr).*(low.memory|lmk)' \
        "$scratch/events.log" || true)"
    [[ "$count" =~ ^[0-9]+$ ]] || fail 'No se pudo filtrar el registro de incidencias'
    printf 'stage=%s relevantIncidents=%s\n' "$stage" "$count" >> "$evidence/incidents.txt"
    [[ "$count" == 0 ]] || fail 'ANR, crash o muerte por memoria del sistema o de AuraQR'
}
check_incidents

stage=isolation
device root
device wait-for-device
[[ "$(device shell id -u)" == 0 ]] || fail 'ADB root no disponible en el AVD desechable'
device shell setprop bionic.linker.16kb.app_compat.enabled false
device shell setprop pm.16kb.app_compat.disabled true
[[ "$(device shell getprop bionic.linker.16kb.app_compat.enabled)" == false &&
   "$(device shell getprop pm.16kb.app_compat.disabled)" == true ]] || fail 'Compatibilidad de páginas no desactivada'
device shell cmd connectivity airplane-mode enable
device shell svc wifi disable
if [[ "$(device shell service check phone)" == 'Service phone: found' ]]; then
    device shell svc data disable
fi
for iptables in iptables ip6tables; do
    device shell "$iptables" -I OUTPUT 1 '!' -o lo -j REJECT
done
check_isolation() {
    local iptables first
    for iptables in iptables ip6tables; do
        device shell "$iptables" -C OUTPUT '!' -o lo -j REJECT
        first="$(device shell "$iptables" -S OUTPUT | awk '$1 == "-A" && !seen++ {print}')"
        [[ "$first" == '-A OUTPUT ! -o lo -j REJECT'* ]] || fail 'La regla de aislamiento no es la primera de OUTPUT'
    done
    [[ "$(device shell settings get global airplane_mode_on)" == 1 ]] || fail 'Modo avión no acreditado'
}
check_isolation
if device shell ping -c 1 -W 2 1.1.1.1 > "$scratch/ping.log" 2>&1; then
    fail 'El AVD tiene salida externa'
fi
check_isolation
printf 'pageCompatibility=off\nipv4Ipv6Egress=blocked\n' >> "$evidence/checks.txt"

stage=android_stability
installed="$(device shell pm list packages "$package")"
if grep -Fxq "package:$package" <<< "$installed"; then
    fail 'AuraQR ya estaba instalada antes de comprobar la estabilidad'
fi
for sample in 15 30 45 60; do
    sleep 15
    check_incidents
    check_isolation
    [[ "$(device shell getprop sys.boot_completed)" == 1 ]] || fail 'Android dejó de responder durante la estabilización'
    device shell dumpsys -t 5 activity activities > "$scratch/activity-warmup.txt"
    grep -q 'ACTIVITY MANAGER ACTIVITIES' "$scratch/activity-warmup.txt" || fail 'Activity Manager no responde'
    printf 'androidPreinstallSample=%ss %s\n' "$sample" \
        "$(device shell cat /proc/meminfo | awk '/^MemAvailable:/ {print}')" >> "$evidence/checks.txt"
done
printf 'androidPreinstallStability=PASS\n' >> "$evidence/checks.txt"

stage=install
printf '%s\n' "$(openssl rand -hex 24)" > "$scratch/key.pass"
keytool -genkeypair -alias auraqr16k -keyalg RSA -keysize 2048 -validity 2 \
    -dname 'CN=AuraQR 16KB QA' -storetype PKCS12 -keystore "$scratch/qa.p12" \
    -storepass:file "$scratch/key.pass" > "$scratch/keytool.log" 2>&1
bundle get-device-spec --adb="$adb" --device-id="$serial" --output="$scratch/device-spec.json"
bundle build-apks --bundle="$aab" --device-spec="$scratch/device-spec.json" --output="$scratch/auraqr.apks" \
    --ks="$scratch/qa.p12" --ks-key-alias=auraqr16k --ks-pass="file:$scratch/key.pass"
(cd "$scratch" && sha256sum auraqr.apks) >> "$evidence/SHA256SUMS.txt"
unzip -q "$scratch/auraqr.apks" '*.apk' -d "$scratch/splits"
qa_cert=''
while IFS= read -r -d '' apk; do
    cert="$("$apksigner" verify --print-certs "$apk" | awk '/certificate SHA-256 digest:/ {print $NF}')"
    [[ "$cert" =~ ^[0-9a-fA-F]{64}$ ]] || fail 'Firma de split no acreditada'
    [[ -z "$qa_cert" || "$cert" == "$qa_cert" ]] || fail 'Firmas diferentes entre splits'
    qa_cert="$cert"
    (cd "$scratch/splits" && sha256sum -- "${apk#"$scratch/splits/"}") >> "$evidence/SHA256SUMS.txt"
done < <(find "$scratch/splits" -name '*.apk' -print0)
[[ -n "$qa_cert" ]] || fail 'No se encontraron APK firmados'
printf 'qaSignerSha256=%s\n' "$qa_cert" >> "$evidence/checks.txt"
check_isolation
bundle install-apks --adb="$adb" --device-id="$serial" --apks="$scratch/auraqr.apks"
device shell pm path "$package" > "$scratch/installed-splits.txt"
grep -q '/base.apk$' "$scratch/installed-splits.txt"
grep -q '/split_config.x86_64.apk$' "$scratch/installed-splits.txt"
device shell dumpsys package "$package" > "$scratch/package.txt"
grep -Eq 'versionCode=12([[:space:]]|$)' "$scratch/package.txt"
grep -Eq 'versionName=0\.1\.4([[:space:]]|$)' "$scratch/package.txt"
printf 'installation=PASS\nversion=0.1.4+12\n' >> "$evidence/checks.txt"

stage=launches
device shell svc power stayon true
device shell input keyevent 82
for attempt in 1 2; do
    check_isolation
    check_incidents
    device shell am force-stop "$package"
    device shell am start -W -n "$package/.MainActivity" > "$scratch/am-start.txt"
    grep -q '^Status: ok' "$scratch/am-start.txt" || fail 'La actividad principal no arrancó'
    printf 'launch=%s status=ok\n' "$attempt" > "$evidence/launch-$attempt.txt"
    pid="$(device shell pidof "$package")"
    [[ "$pid" =~ ^[0-9]+$ ]] || fail 'PID inicial no disponible'
    for sample in 15 30 45 60; do
        sleep 15
        check_isolation
        check_incidents
        [[ "$(device shell pidof "$package")" == "$pid" ]] || fail 'El PID cambió durante el arranque'
        device shell dumpsys activity activities > "$scratch/activity.txt"
        grep -Eq 'topResumedActivity=.*com\.auralabs\.lectorqr/' "$scratch/activity.txt" || fail 'AuraQR perdió el primer plano'
        printf 'sample=%ss pid=%s foreground=yes %s\n' "$sample" "$pid" \
            "$(device shell cat /proc/meminfo | awk '/^MemAvailable:/ {print}')" >> "$evidence/launch-$attempt.txt"
    done
done
stage=PASS_INSTALL_AND_TWO_LAUNCHES
