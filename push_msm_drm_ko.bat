@echo off
chcp 65001 >nul
setlocal EnableDelayedExpansion

echo [1/7] Requesting root access...
adb root | findstr /i "restarting" >nul && echo       OK: adbd restarted as root || echo       WARN: Device may already be rooted or not supported

echo [2/7] Remounting filesystem...
adb remount | findstr /i "succeeded" >nul && echo       OK: Remount succeeded || (echo       FAIL: Remount failed! & pause & exit /b 1)

echo [3/7] Removing old msm_drm.ko...
adb shell rm -rf /vendor_dlkm/lib/modules/msm_drm.ko
echo       Done.

echo [4/7] Verifying old file removal...
adb shell ls /vendor_dlkm/lib/modules/msm_drm.ko 2>nul | findstr /i "No such file" >nul && echo       OK: Old file removed || echo       WARN: File still exists or path invalid

echo [5/7] Pushing new msm_drm.ko...
adb push "\\10.71.255.189\yxb_sdc1\kc3\VENDOR\out\target\product\vienna\dlkm\lib\modules\msm_drm.ko" /vendor_dlkm/lib/modules/msm_drm.ko
if !errorlevel! neq 0 (echo       FAIL: Push failed! Check network/path. & pause & exit /b 1) else (echo       OK: Push completed.)

echo [6/7] Verifying new file...
adb shell ls -l /vendor_dlkm/lib/modules/msm_drm.ko
echo       (Above is the new file info)

echo [7/7] Rebooting device...
adb reboot
echo       OK: Reboot command sent. Script finished.
pause