# Windows Support Diagnostics

Диагностика Windows Server одной командой. Сбор CPU, памяти, диска, процессов, RDP-сеансов и событий Windows продолжается после закрытия PowerShell и отключения RDP. По завершении получается ZIP с журналами, CSV, `summary.json` и кратким `summary.html`.

## Запуск на 60 минут

Откройте **Windows PowerShell от администратора** на проверяемом сервере. Вставьте следующую строку целиком — отдельно скачивать файлы не нужно:

```powershell
$p="$env:TEMP\SupportDiag.ps1"; [Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest 'https://raw.githubusercontent.com/nil3232/windows-support-diag/main/SupportDiag.ps1' -UseBasicParsing -OutFile $p -ErrorAction Stop; powershell.exe -NoProfile -ExecutionPolicy Bypass -File $p -Minutes 60
```

Меняйте `60` на нужное число минут: **1–1440**. Дождитесь сообщения `READY`, затем можно отключаться. Если READY не подтверждён, используйте Status и проверьте errors.txt.

Интервал измерений по умолчанию 10 секунд; выгрузки событий — 120 секунд. Можно добавить `-SampleSeconds 15 -EventSeconds 300`. Эти интервалы — целевые: экспорт журналов и системная нагрузка увеличивают паузы. Длительность включает начальную подготовку; окончательная выгрузка и упаковка добавляют время.

## Забрать результат

После завершения:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\ProgramData\WindowsSupportDiag\SupportDiag.ps1' -Action Collect
```

Команда покажет полный путь к архиву `C:\ProgramData\WindowsSupportDiag\Report-<server>-<run>.zip`. Скопируйте ZIP на свой компьютер. Сборщик ничего не отправляет по сети.

Статус и досрочное завершение:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\ProgramData\WindowsSupportDiag\SupportDiag.ps1' -Action Status
powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\ProgramData\WindowsSupportDiag\SupportDiag.ps1' -Action Stop
```

`Collect` не прерывает активный сбор. `Stop` завершает его и получает архив. При необходимости можно указать `-Run 'полный путь к конкретной папке'` и `-Destination 'C:\Temp\Report.zip'`. По умолчанию выбирается последняя папка запуска.

## Скачать заранее, запустить позже без интернета

В команде загрузки замените `-Minutes 60` на `-DownloadOnly`. Затем на том же сервере:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\ProgramData\WindowsSupportDiag\SupportDiag.ps1' -Offline -Minutes 120
```

Для переноса на сервер без интернета скачайте файлы `SupportDiag.ps1`, `Collector.ps1`, `manifest.json`. Разместите все три файла в одной папке, например `C:\Temp\SupportDiag`, затем выполните:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\Temp\SupportDiag\SupportDiag.ps1' -Offline -Minutes 120
```

SHA256 сборщика проверяется по манифесту перед запуском. Это проверка согласованности файлов, а не цифровая подпись. Для фиксации версии используйте SHA коммита вместо `main` в URL загрузки и передавайте тот же SHA параметром `-Ref`.

## Что собирается

- Версия ОС, сборка/UBR, обновления, CPU/RAM, диски и свободное место.
- CPU/память, первые 30 процессов по памяти, дисковая очередь/скорость/задержки; CPU процесса указан в накопленных секундах.
- Сеансы `quser`/`qwinsta`, службы, профили, адреса/маршруты/прослушиваемые TCP-порты, выбранные настройки RDP.
- System, Application, User Profile Service, LocalSessionManager, RemoteConnectionManager, Winlogon, GroupPolicy — TXT и EVTX.
- Выбранные события аутентификации из Security. По 3000 последних записей для текстовой выгрузки; EVTX ограничены 10000 последними RecordID и последними 24 часами. Для долгого сбора архив не гарантирует полную историю каждого канала.

## Поведение и ограничения

Создаётся временная задача `WindowsSupportDiag-*` от SYSTEM и папка с доступом Administrators/SYSTEM. Задача удаляется после успешной упаковки, исходные файлы сохраняются. Повторный Start блокируется при наличии задачи предыдущего сбора: сначала проверьте Status и завершите предыдущий запуск.

После перезагрузки задача пытается выгрузить журналы и упаковать сохранённый запуск, **не продолжая исходный интервал**. CSV сбрасываются на диск, новые снимки заменяют предыдущие только после успешной записи. При жёстком выключении могут потеряться последние записи или данные из кэша диска; абсолютной гарантии сохранности нет.

Настройки служб, RDP, брандмауэра и обновлений не меняются; программы не устанавливаются, перезагрузки не инициируются. Отключённые каналы событий остаются отключёнными. Дампы памяти, снимки экрана, документы и командные строки процессов не собираются. Журналы могут содержать имена пользователей, IP и чувствительный текст приложений — передавайте архив только тому, кому разрешён доступ к этим данным.

Требования: Windows PowerShell **5.1**, Windows Task Scheduler, права администратора, локальный диск с доступным местом. Исходный сборщик проверен на Windows Server 2019; универсальная версия проверяется тестами под PowerShell 5.1. Полная работа на других версиях Windows и восстановление после аварийного отключения требуют проверки в вашей среде. PowerShell 7 не является проверенной средой запуска.

## Разработка

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Verify.ps1
```

Тесты не создают задач планировщика и не меняют настройки ОС. Папка `test-output` исключена из Git. Логи клиентов и архивы в репозиторий не добавляются.
