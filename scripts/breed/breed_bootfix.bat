@echo off
:: WDR3600 32 MB temiz imaj - Breed telnet ile yazma (yonetici gerekir)
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Yonetici yetkisi isteniyor...
    powershell -Command "Start-Process cmd -ArgumentList '/k \"\"%~f0\"\"' -Verb RunAs"
    exit /b
)
title WDR3600 Breed acilis duzeltmesi (yazma yok)
set LOG=%~dp0breed_bootfix_log.txt
echo ==== %date% %time% bat basladi >> "%LOG%"

echo [1/4] Ethernet 192.168.1.2 yapiliyor (Wi-Fi internet kesilmez)...
netsh interface ipv4 set address name="Ethernet" source=static address=192.168.1.2 mask=255.255.255.0 gateway=none >> "%LOG%" 2>&1
netsh interface ipv4 set interface "Ethernet" metric=100 >> "%LOG%" 2>&1
:: Breed'in imaji PC'den indirebilmesi icin gecici kural (yalnizca 192.168.1.1 -> TCP 8000)
timeout /t 5 /nobreak >nul

echo.
echo ========================================================
echo  SIMDI ROUTER'I BREED MODUNA ALIN:
echo  1. Router'i guc dugmesinden KAPATIN.
echo  2. WPS/Reset dugmesini BASILI TUTUN.
echo  3. Basili tutarken router'i ACIN.
echo  4. SYS isigi HIZLI yanip sonunce dugmeyi BIRAKIN.
echo ========================================================
echo.

echo [2/4] Breed acilis duzeltmesi betigi calisiyor...
python -I "%~dp0breed_bootfix.py"
set RC=%errorlevel%

echo [3/4] Gecici kural kaldiriliyor, Ethernet otomatik IP (DHCP) yapiliyor...
netsh interface ipv4 set address name="Ethernet" source=dhcp >> "%LOG%" 2>&1
netsh interface ipv4 set dnsservers name="Ethernet" source=dhcp >> "%LOG%" 2>&1
netsh interface ipv4 set interface "Ethernet" metric=100 >> "%LOG%" 2>&1

if not "%RC%"=="0" (
    echo HATA olustu, ayrintilar: %LOG%
    echo ==== bat bitti: HATA rc=%RC% >> "%LOG%"
    goto end
)
echo [4/4] OpenWrt 192.168.1.1 bekleniyor (en fazla ~5 dk)...
for /l %%i in (1,1,100) do (
    ping -n 1 -w 1000 192.168.1.1 | find "TTL=" >nul && goto up
    timeout /t 2 /nobreak >nul
)
echo Router 5 dk icinde 192.168.1.1'de gorunmedi. >> "%LOG%"
echo Router 5 dk icinde gorunmedi. Ayrinti: %LOG%
goto end
:up
echo ==== bat bitti: router 192.168.1.1'de ACIK >> "%LOG%"
echo BASARILI: router 192.168.1.1'de acik.
:end
pause
