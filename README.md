sudo dd if=/dev/zero of=/swapfile bs=1M count=1024
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
apt install zram-tools
nano /etc/default/zramswap
Откроется файл, дописать в него:
ALGO=zstd
PERCENT=60
PRIORITY=100
Далее Ctrl+X, Y, Y (сохранить изменения)
systemctl restart zramswap
Проверить:
    zramctl: Показывает статистику сжатия.
    swapon --show: Показывает устройства подкачки и их приоритет.
    htop: Показывает использование, в swapЭто инструкция по созданию гибридной системы подкачки (swap) в Linux, которая сочетает:

Обычный swap-файл на диске (медленный, но большой объём)
zram — сжатая подкачка прямо в оперативной памяти (очень быстрая, но ограничена объёмом RAM)

Цель — сделать систему гораздо более отзывчивой при нехватке оперативки, особенно на ноутбуках / ПК с 8–16 ГБ RAM, где часто открыто много вкладок браузера, мессенджеры, IDE и т.д.
Что делает каждая команда по порядку

sudo dd if=/dev/zero of=/swapfile bs=1M count=1024
→ Создаёт файл подкачки размером 1 ГБ (1024 × 1 МБ) в корне файловой системы.
sudo chmod 600 /swapfile
→ Делает файл доступным только для root (важно для безопасности).
sudo mkswap /swapfile
→ Форматирует этот файл как swap-пространство.
sudo swapon /swapfile
→ Включает его как устройство подкачки (обычно с приоритетом -2 или -1).
apt install zram-tools
→ Устанавливает пакет для удобного управления zram (чаще всего используется в Debian/Ubuntu/Mint/Pop!_OS и производных).
nano /etc/default/zramswap
→ Редактирование конфига zram-tools. Добавляются/раскомментируются строки:textALGO=zstd
PERCENT=60
PRIORITY=100Что они означают (2025–2026 годы, актуальные значения):
ALGO=zstd — алгоритм сжатия. Сейчас считается лучшим компромиссом скорость ↔ степень сжатия (часто 2.5–3.5:1 на типичных данных рабочего стола).
PERCENT=60 — zram получит до 60% от объёма физической RAM (очень щедро; раньше чаще ставили 25–50%).
PRIORITY=100 — очень важный параметр. Делает zram самым приоритетным устройством подкачки (чем выше число — тем выше приоритет). Обычный swap-файл обычно получает приоритет -2…0 → система будет почти всегда сначала пытаться использовать zram, и только когда он заполнится — писать на диск.

systemctl restart zramswap
→ Применяет новую конфигурацию zram.

Как правильно настроить в 2026 году (рекомендации)
Вариант из твоей инструкции довольно агрессивный (60% RAM под zram + 1 ГБ на диске). Вот более сбалансированные современные подходы:


















































Сценарийzram размерALGOPRIORITYswap-файл на SSDswappinessКомментарий8–12 ГБ RAM, много вкладок50–60%zstd1002–4 ГБ60–100Твой вариант — нормально16–24 ГБ RAM, обычный десктоп33–50%zstd1004–8 ГБ60–80Золотая середина32+ ГБ RAM25–33%zstd1008–16 ГБ или вообще отключить10–30zram почти не нуженОчень мало RAM (≤6 ГБ)75–100%zstd1004–8 ГБ100–180Максимально выжимаем RAM
Дополнительные улучшения (часто рекомендуют):
Bash# Делаем swap-файл постоянным (чтобы включался после перезагрузки)
echo '/swapfile none swap sw,pri=-1 0 0' | sudo tee -a /etc/fstab

# Оптимальный swappiness для zram (система охотнее сбрасывает в сжатую память)
sudo sysctl vm.swappiness=80
# Чтобы сохранилось после перезагрузки:
echo 'vm.swappiness=80' | sudo tee /etc/sysctl.d/99-swappiness.conf
Как проверить, что всё работает правильно
Bash# Показывает zram-устройства и степень сжатия (самое интересное — COMPR / ORIG)
zramctl

# Показывает все swap-устройства и их приоритеты (должно быть zram с prio 100 выше всех)
swapon --show

# Смотрим в реальном времени
htop   → клавиша F2 → Meters → Swap (или просто столбец SWAP)
free -h
Типичный хороший результат (пример на 16 ГБ RAM):

zram ~8–9 ГБ (60%)
степень сжатия 2.8–3.4:1
swap на диске используется только при очень сильной нагрузке

Если что-то не работает — пиши вывод zramctl, swapon --show и сколько у тебя RAM — подскажу точнее.sourcesу меня debian server 1 гб ramУ тебя сервер на Debian с 1 ГБ RAM — это очень мало даже для минималистичных задач в 2026 году (веб-сервер, бот, маленький VPN, мониторинг и т.д. уже могут давить). Без подкачки система будет быстро убиваться OOM-killer.
Твоя исходная инструкция (1 ГБ swap-файл + zram 60%) на 1 ГБ RAM — слишком агрессивно, zram может сожрать слишком много реальной памяти на overhead + метаданные, и сервер начнёт тормозить ещё сильнее.
Рекомендуемая конфигурация именно для 1 ГБ RAM (сервер)
Вариант А — самый стабильный и рекомендуемый (2025–2026)

zram — основной swap (быстрый, сжатый)
маленький swap-файл на диске — только на крайний случай

Bash# 1. Создаём маленький swap-файл 512–1024 МБ (лучше на SSD, если диск медленный — 512 МБ хватит)
sudo fallocate -l 768M /swapfile          # или dd, если fallocate не работает
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile

# Делаем постоянным
echo '/swapfile none swap sw,pri=-2 0 0' | sudo tee -a /etc/fstab

# 2. Устанавливаем zram (если ещё не стоит)
sudo apt update
sudo apt install zram-tools

# 3. Настраиваем /etc/default/zramswap (nano или vim)
sudo nano /etc/default/zramswap
Вставь / измени следующие строки (раскомментируй, если с #):
textALGO=zstd
PERCENT=100          # ← или 150, если хочешь агрессивнее (многие так делают на 1 ГБ)
PRIORITY=100

PERCENT=100 → zram получит ~1 ГБ (реально использует 300–500 МБ при типичном сжатии 2–3:1)
zstd — лучший выбор в 2026: хорошее сжатие + адекватная скорость на слабых CPU
PRIORITY=100 — zram будет использоваться первым (дисковый swap только когда zram забит)

Сохрани (Ctrl+O → Enter → Ctrl+X)
Bash# Применяем
sudo systemctl restart zramswap

# Делаем swappiness высоким — серверу полезно активно сбрасывать в zram
sudo sysctl vm.swappiness=100
# Чтобы сохранилось навсегда
echo 'vm.swappiness=100' | sudo tee /etc/sysctl.d/99-swappiness.conf
Вариант Б — если хочешь ещё агрессивнее (очень много мелких процессов)
Bash# В /etc/default/zramswap
ALGO=zstd
PERCENT=150          # или даже 200 — даёт ~1.5–2 ГБ виртуального swap после сжатия
PRIORITY=200         # ещё выше приоритет

swappiness=120–180

Многие VPS/контейнеры на 1 ГБ именно так и живут (PERCENT=150–200 + zstd).
Что проверить после настройки
Bash# zram должен быть ~1 ГБ (или больше), алгоритм zstd
zramctl

# Должно быть два swap: zram prio 100 → диск prio -2
swapon --show

# Смотрим степень сжатия (самое интересное — DATA / COMPR)
zramctl --output-all

free -h
Ожидаемый результат при нагрузке:

zram DISKSIZE ≈ 1000–1500 МБ
COMPR / DATA ≈ 2.0–3.5 : 1 (чем выше — тем лучше)
дисковый swap почти не используется

Дополнительные советы для 1 ГБ сервера

Отключи ненужные сервисы (apparmor? bluetooth? cups? snapd?)
Используй легковесные альтернативы: nginx вместо apache, redis/memcached экономно, postgresql → лучше sqlite если можно
Логи → в ramfs/tmpfs или journald с лимитом
Ограничь процессы ulimit / systemd MemoryMax=
Мониторь: htop, vmstat 1, cat /proc/pressure/memory

Если скажешь, что именно крутится на сервере (nginx+php? docker? wireguard? nextcloud? просто ssh?), подскажу более точные тюнинги. Удачи — с такой настройкой 1 ГБ может жить довольно бодро!sourcesecho '/swapfile none swap sw,pri=-2 0 0' | sudo tee -a /etc/fstab
/swapfile none swap sw,pri=-2 0 0Да, эта строка — правильный способ сделать swap-файл постоянным (чтобы он автоматически подключался после каждой перезагрузки сервера).
Bashecho '/swapfile none swap sw,pri=-2 0 0' | sudo tee -a /etc/fstab
После выполнения этой команды (и только после неё) вторая строка, которую ты показал:
text/swapfile none swap sw,pri=-2 0 0
— это просто содержимое, которое добавилось в конец /etc/fstab. Можешь проверить так:
Bashcat /etc/fstab
Там в конце должна появиться именно эта строка.
Почему именно так?

/swapfile — путь к файлу
none — точка монтирования (для swap всегда none)
swap — тип файловой системы
sw,pri=-2 — флаги: sw = включить как swap, pri=-2 = низкий приоритет (чтобы zram с pri=100 использовался первым)
0 0 — dump и fsck (для swap всегда 0 0)

Это стандартный и безопасный вариант для Debian.
Что делать дальше (полный чек-лист для твоего 1 ГБ сервера)

Убедись, что swap-файл уже создан и включён:Bashsudo swapon --showДолжен показаться /swapfile с pri=-2 (или -1, если не указывал pri раньше).
Настрой zram (если ещё не сделал):Bashsudo apt install zram-tools
sudo nano /etc/default/zramswapРекомендую для 1 ГБ RAM на сервере такой консервативный, но эффективный вариант (основан на свежих рекомендациях Debian Wiki + опыте low-RAM систем 2025–2026):textALGO=zstd
PERCENT=100          # или 150, если хочешь агрессивнее (многие ставят 100–200 на 1 ГБ)
PRIORITY=100
PERCENT=100 → zram ~1 ГБ (после сжатия обычно даёт 2–3.5 ГБ полезного swap-пространства)
zstd — лучший алгоритм сейчас (хорошее сжатие + скорость)
PRIORITY=100 → всегда выше, чем дисковый swap (-2)
Сохрани → примени:Bashsudo systemctl restart zramswap
Установи swappiness высоко (очень важно для zram на слабом сервере):Bashsudo sysctl vm.swappiness=100
echo 'vm.swappiness=100' | sudo tee /etc/sysctl.d/99-swappiness.conf(100 — хороший баланс: система активно использует zram, но не умирает от перегрузки. Можно попробовать 120–150, если нагрузка всё равно убивает OOM.)
Перезагрузи сервер и проверь всё после загрузки:Bashsudo reboot
# после перезагрузки:
free -h
swapon --show               # должен быть zram pri 100 + swapfile pri -2
zramctl                     # DISKSIZE ~1024M, ALGORITHM zstd
zramctl --output-all        # смотри COMPR / ORIG — степень сжатия (чем выше — тем лучше)

Если сервер — это что-то вроде lightweight веб-сервер (nginx + php-fpm/small app), бот, мониторинг (prometheus/node-exporter), VPN (wireguard) — такая настройка обычно позволяет комфортно жить на 1 ГБ без постоянных убийств процессов.
Если после нагрузки zram заполняется полностью и всё равно начинается thrashing — пиши вывод zramctl + free -h + swapon --show + что именно крутится на сервере, подкорректируем PERCENT или swappiness. Удачи!sourcescat /etc/fstab
# /etc/fstab: static file system information.
# 
# Use 'blkid' to print the universally unique identifier for a
# device; this may be used with UUID= as a more robust way to name devices
# that works even if disks are added and removed. See fstab(5).
# 
# <file system> <mount point> <type> <options> <dump> <pass>
# / was on /dev/vda2 during curtin installation
/dev/vda2 / ext4 defaults 0 1
/swapfile none swap sw 0 0
/swapfile none swap sw,pri=-2 0 0Твой /etc/fstab сейчас выглядит так:
text/dev/vda2 / ext4 defaults 0 1
/swapfile none swap sw 0 0
/swapfile none swap sw,pri=-2 0 0
Это дубликат одной и той же записи для /swapfile. Система обычно справляется (swap активируется один раз), но лучше почистить, чтобы избежать потенциальных предупреждений при загрузке, дублирующихся приоритетов или мелких глюков в будущем (некоторые инструменты/скрипты могут ругаться на дубли).
Что происходит на практике

Linux kernel и swapon -a (который вызывается при загрузке) увидят две попытки активировать один и тот же файл как swap.
Обычно вторая строка просто игнорируется (если swap уже активен), или приоритет применяется только к одной.
Но это некрасиво и может привести к логам вроде "already active" или "duplicate entry" в journalctl.

Как исправить (рекомендую вариант с приоритетом)

Открой файл для редактирования:Bashsudo nano /etc/fstab
Удали одну из двух строк про /swapfile. Оставь только эту (с приоритетом, чтобы zram был выше):text/swapfile none swap sw,pri=-2 0 0Полный файл должен стать примерно таким (остальное не трогай):text# /etc/fstab: static file system information.
#
# <file system> <mount point> <type> <options> <dump> <pass>
# / was on /dev/vda2 during curtin installation
/dev/vda2 / ext4 defaults 0 1
/swapfile none swap sw,pri=-2 0 0
sw,pri=-2 — низкий приоритет (zram с PRIORITY=100 будет использоваться первым).
none — правильный mount point для swap (рекомендуется в man fstab).
sw — включает swap (можно писать просто defaults, но sw тоже работает).

Сохрани (Ctrl+O → Enter → Ctrl+X).
Проверь, что синтаксис нормальный (не обязательно, но полезно):Bashsudo findmnt --verifyЕсли ошибок нет — отлично.
Перезагрузи сервер (или просто переактивируй swap, чтобы убедиться):Bashsudo swapoff -a
sudo swapon -a
Посмотри результат:Bashswapon --show
# Ожидаемый вывод: одна строка для /swapfile с pri=-2 (или -1, если pri не применился)
# И строка для zram с pri=100 (если zram включён)

free -h
zramctl   # если zram настроен

После этого дубликат исчезнет, и всё будет чисто + приоритеты сохранятся (zram → диск).
Если после правки что-то сломалось (редко, но бывает на VPS) — просто верни старую версию из бэкапа или добавь строку обратно. Пиши вывод swapon --show после изменений, если нужно уточнить. Удачи с сервером!sourcessudo findmnt --verify
none
   [W] non-bind mount source /swapfile is a directory or regular file
   [W] your fstab has been modified, but systemd still uses the old version;
       use 'systemctl daemon-reload' to reload
0 parse errors, 0 errors, 2 warningsТвой вывод sudo findmnt --verify:
textnone
   [W] non-bind mount source /swapfile is a directory or regular file
   [W] your fstab has been modified, but systemd still uses the old version;
       use 'systemctl daemon-reload' to reload
0 parse errors, 0 errors, 2 warnings
Это нормально и не опасно — система загрузится без проблем. Оба предупреждения — типичные для swap-файла в fstab, а не реальные ошибки.
Разбор предупреждений

[W] non-bind mount source /swapfile is a directory or regular file
Это предупреждение появляется всегда, когда в fstab указан swap-файл (не раздел диска).
findmnt --verify ожидает, что source — это устройство или bind-mount (директория/файл с опцией bind).
Но swap-файл — обычный файл, а не блочное устройство.
Инструмент просто "жалуется", что source — regular file, хотя для swap это нормально и работает.
→ Это ложное/косметическое предупреждение. Игнорируй его полностью — тысячи людей с swap-файлом видят то же самое (Debian, Ubuntu, Mint, Arch и т.д.).

[W] your fstab has been modified, but systemd still uses the old version; use 'systemctl daemon-reload' to reload
Ты недавно изменил /etc/fstab (удалил дубликат строки).
Systemd (init-система) кэширует fstab при загрузке, и пока не перезагрузишь или не сделаешь reload — он видит старую версию.
→ Это временное предупреждение, исчезнет после перезагрузки или команды ниже.

Что сделать прямо сейчас (чтобы убрать второе предупреждение и быть чистым)
Bashsudo systemctl daemon-reload
После этого снова проверь:
Bashsudo findmnt --verify
Должно остаться только одно предупреждение:
textnone
   [W] non-bind mount source /swapfile is a directory or regular file
0 parse errors, 0 errors, 1 warning
(Или даже без предупреждений в некоторых версиях findmnt — зависит от util-linux версии в Debian).
Финальная проверка всего swap + zram
Bash# Все swap-устройства и приоритеты (zram должен быть pri=100, /swapfile pri=-2)
swapon --show

# zram статистика (DISKSIZE ~1 ГБ или больше, ALGORITHM zstd, степень сжатия COMPR/ORIG)
zramctl
zramctl --output-all   # подробнее

# Общая память + swap
free -h

# Если хочешь перезагрузить и убедиться, что всё подхватывается автоматически
sudo reboot
# после перезагрузки повтори swapon --show и zramctl
Если после daemon-reload и перезагрузки предупреждение про "regular file" всё равно раздражает — можно просто игнорировать (это не влияет на работу). Альтернатива — использовать swap-раздел вместо файла (но на VPS это обычно неудобно, требует repartition).
Всё в порядке — твой сервер настроен правильно для 1 ГБ RAM. Если под нагрузкой увидишь, что zram заполняется полностью и начинается thrashing (сильные тормоза) — пиши вывод zramctl в момент проблемы, подкрутим PERCENT или swappiness. Удачи!

Всё выглядит очень хорошо и правильно настроено для сервера с ~2 ГБ RAM (точнее 1.9 GiB по free -h). Это одна из лучших гибридных конфигураций swap + zram для low-memory систем в 2025–2026 годах. Разберём по пунктам, что у тебя сейчас и почему это ок (или почти идеально).
Текущая конфигурация — анализ
ПараметрТвоё значениеОценкаКомментарий / Рекомендация 2026vm.swappiness100ОтличноИдеально для zram: система активно использует сжатую память, но не агрессивно (не 180+). На серверах с zram часто ставят 80–120. Твой 100 — золотая середина.zram ALGORITHMzstdЛучший выборСамый сбалансированный сейчас (хорошее сжатие + скорость). lz4 быстрее, но хуже степень сжатия — zstd выигрывает на большинстве серверных нагрузок.zram DISKSIZE1.2G (≈60% от 1.9 GiB)Хорошо, но можно чуть уменьшить~60% — нормально для <4 ГБ RAM (Debian Wiki рекомендует до 60%). При типичном сжатии 2.5–3.5:1 даёт ~3–4 ГБ полезного swap. Если overhead CPU беспокоит — попробуй PERCENT=50 (≈1 ГБ).zram PRIORITY100ПравильноВыше дискового swap (-2) — zram всегда первый.swapfile512M, pri=-2ХорошоМаленький файл на диске — страховка на случай, если zram забьётся полностью (OOM-killer реже сработает).Текущая нагрузкаDATA 4K → COMPR 59BПочти пусто (степень сжатия огромная)Нормально — сейчас почти ничего не в swap. TOTAL 20K — overhead минимальный.Общий Swap1.7 GiB (1.2G zram + 0.5G file)ОтличноПолезный объём после сжатия может быть 3–5+ ГБ.free -hMem: used 985 MiB, available 982 MiB
Swap: used 16 KiBСистема комфортно живёт, swap почти не используетсяbuff/cache 1.0 GiB — нормально (Linux использует свободную RAM под кэш).
Вывод: Всё настроено правильно и эффективно. Нет ошибок, приоритеты верные, zram включён первым, swappiness подходит под zram. На 2 ГБ это даёт заметный прирост отзывчивости по сравнению с чистым дисковым swap.
Возможные мелкие улучшения (не обязательно, но можно)

Если хочешь консервативнее (меньше overhead на CPU/RAM)
В /etc/default/zramswap поставь:textALGO=zstd
PERCENT=50
PRIORITY=100→ zram станет ~950–1000 МБ (вместо 1.2G).
Затем:Bashsudo systemctl restart zramswapМногие на 2–4 ГБ RAM в 2025–2026 ставят 50% или даже 25–33%, чтобы не "откусывать" слишком много под метаданные zram.
Если нагрузка вырастет и thrashing начнётся
Подними swappiness до 120–150 (ещё агрессивнее к zram).
Или уменьши до 60–80 (если хочешь дольше держать данные в чистой RAM).

Мониторинг под нагрузкой
Запусти что-то тяжёлое (компиляция, много процессов) и посмотри:Bashwatch -n 2 'zramctl --output-all && free -h'Ключевые метрики:
COMPR / DATA → степень сжатия (хорошо 2.5+:1 и выше)
MEM-USED → сколько реальной RAM жрёт zram (не должно превышать 30–40% физической при нормальной работе)

Дополнительные тюнинги для сервера (опционально)Bash# Чтобы кэш не вытеснялся слишком агрессивно
echo 'vm.vfs_cache_pressure=50' | sudo tee /etc/sysctl.d/99-cache.conf
sudo sysctl -p /etc/sysctl.d/99-cache.conf
