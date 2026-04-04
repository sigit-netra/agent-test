cd /usr/local/mnt/sda1

uclient-fetch -O rut-datalogger-new "https://raw.githubusercontent.com/sigit-netra/agent-test/main/rut-datalogger"
uclient-fetch -O ui-rut-datalogger-new "https://raw.githubusercontent.com/sigit-netra/agent-test/main/ui-rut-datalogger"

chmod +x rut-datalogger-new ui-rut-datalogger-new
ls -lh rut-datalogger-new ui-rut-datalogger-new