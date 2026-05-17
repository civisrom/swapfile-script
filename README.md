# swap-setup

Автоматическая настройка гибридной подкачки (swapfile + zram) для Debian/Ubuntu VPS с малым объёмом RAM (512 МБ – 8 ГБ).

## Быстрая установка

Одна команда — скачивает, устанавливает в `/usr/local/sbin/` и запускает интерактивный мастер:

```bash
wget -qO- https://raw.githubusercontent.com/civisrom/swapfile-script/main/install.sh | sudo bash
```

С параметрами (без интерактивного режима):

```bash
wget -qO- https://raw.githubusercontent.com/civisrom/swapfile-script/main/install.sh | sudo bash -s -- --ram 1
```

После установки скрипт доступен как системная команда:

```bash
sudo swap-setup.sh --status
sudo swap-setup.sh --remove
```

## Что делает скрипт

1. **Определяет систему** — автоматически определяет ОС, CPU и объём RAM, выводит баннер с информацией
2. **Проверяет конфликты** — проверяет существующую конфигурацию swap (активные устройства, `/etc/fstab`, zramswap) перед установкой
3. **Выполняет preflight-проверки** — проверяет нужные команды, свободное место, тип файловой системы, zram-модуль и поддержку выбранного алгоритма
4. **Создаёт swap-файл staged-методом** на диске с приоритетом `-2`: сначала создаётся и форматируется временный файл, затем он атомарно ставится на место `/swapfile`
5. **Устанавливает и настраивает zram-tools** (сжатая подкачка в RAM, приоритет `100`) и включает сервис `zramswap` на автозапуск
6. **Настраивает `vm.swappiness`** с сохранением после перезагрузки
7. **Обновляет `/etc/fstab` атомарно** и делает резервную копию перед изменением
8. **Проверяет итоговую конфигурацию** — активность `/swapfile`, `/dev/zram0`, приоритеты, размер zram, алгоритм, `vm.swappiness` и запись `/etc/fstab`
9. **Выводит итоговую информацию** — `zramctl`, `swapon --show`, `zramctl --output-all`, `free -h`

## Интерактивный режим

При запуске без параметров скрипт запускает интерактивный мастер настройки:

```bash
sudo bash swap-setup.sh
```

Скрипт покажет:

```
╔══════════════════════════════════════════════════════╗
║  swap-setup.sh — Hybrid Swap + Zram for VPS         ║
╠══════════════════════════════════════════════════════╣
║  OS:    Debian GNU/Linux 12 (bookworm)
║  CPU:   Intel Xeon E5-2680 v4
║  RAM:   1024 MB (~1 GB)
╚══════════════════════════════════════════════════════╝

  Available templates:

  ┌──────┬────────┬──────────────┬───────────┬───────┬──────────┬────────────┐
  │  #   │  RAM   │  Swapfile    │  zram %   │ ALGO  │ PRIORITY │ swappiness │
  ├──────┼────────┼──────────────┼───────────┼───────┼──────────┼────────────┤
  │ 0.5  │ 512MB  │ 1024 MB      │   100%    │ zstd  │   100    │    100     │
  │  1   │ 1GB    │  512 MB      │   100%    │ zstd  │   100    │    100     │ << recommended
  │  2   │ 2GB    │ 1024 MB      │    75%    │ zstd  │   100    │    100     │
  │  3   │ 3GB    │ 1024 MB      │    60%    │ zstd  │   100    │     80     │
  │  4   │ 4GB    │ 1536 MB      │    50%    │ zstd  │   100    │     80     │
  │  6   │ 6GB    │ 2048 MB      │    40%    │ zstd  │   100    │     60     │
  │  8   │ 8GB    │ 2048 MB      │    25%    │ zstd  │   100    │     60     │
  ├──────┼────────┼──────────────┼───────────┼───────┼──────────┼────────────┤
  │  9   │ Manual input — set each parameter yourself                        │
  └──────┴────────┴──────────────┴───────────┴───────┴──────────┴────────────┘

  Select template (0.5, 1-8, or 9 for manual):
```

### Выбор шаблона (0.5, 1, 2, 3, 4, 6, 8)

При выборе шаблона скрипт спросит, хотите ли вы подкорректировать параметры:

```
  Want to adjust individual parameters?
  Edit parameters? [y/N]:
```

Если `y` — можно изменить любой параметр, нажав Enter для сохранения текущего значения.

### Ручной ввод (9)

При выборе `9` скрипт последовательно запросит каждый параметр с подсказками:

```
  1. Swap file size (MB)
     Recommended template for this system: 512 MB
     Swapfile size MB [512]:

  2. Compression algorithm (ALGO)
     Available: zstd | lz4 | lzo | lzo-rle | lz4hc | zlib | 842
     zstd  — best compression ratio (~3:1), moderate CPU (recommended 2025-2026)
     lz4   — fastest, lower compression (~2:1), good for weak CPU
     lzo   — legacy, balanced
     ALGO [zstd]:

  3. zram size as % of RAM (PERCENT)
     With PERCENT=100 on your 1024MB RAM -> zram swap device ~1024 MB
     Range: 25-200 normally, hard limit 300. Recommended template for this system: 100%
     PERCENT [100]:
     -> zram swap device will be ~1024 MB (100% of 1024 MB)

  4. zram swap priority (PRIORITY)
     Higher = used first. Disk swap has priority -2. Range: 0-32767
     PRIORITY [100]:

  5. vm.swappiness
     How eagerly kernel uses swap. Range: 0-200. Template default for this system: 100
     swappiness [100]:
```

Перед установкой показывается итоговый план:

```
  ┌─────────────────────┬─────────────────────────────────────┐
  │ System RAM          │ 1024 MB (~1 GB)                     │
  ├─────────────────────┼─────────────────────────────────────┤
  │ Swap file           │ 512 MB at /swapfile (pri -2)        │
  │ zram ALGO           │ zstd                                │
  │ zram PERCENT        │ 100% (~1024 MB)                     │
  │ zram PRIORITY       │ 100                                 │
  │ vm.swappiness       │ 100                                 │
  └─────────────────────┴─────────────────────────────────────┘

  Swap priority: zram (100) >> disk swap (-2)
  zram logical swap size is ~1024 MB; at ~3:1 compression its data may use ~342 MB RAM

  Proceed with installation? [y/N]:
```

## Шаблоны для разных объёмов RAM

| Параметр | 512 МБ RAM | 1 ГБ RAM | 2 ГБ RAM | 3 ГБ RAM | 4 ГБ RAM | 6 ГБ RAM | 8 ГБ RAM |
|---|---|---|---|---|---|---|---|
| Swap-файл | 1024 МБ | 512 МБ | 1024 МБ | 1024 МБ | 1536 МБ | 2048 МБ | 2048 МБ |
| zram PERCENT | 100% | 100% | 75% | 60% | 50% | 40% | 25% |
| ALGO | zstd | zstd | zstd | zstd | zstd | zstd | zstd |
| PRIORITY | 100 | 100 | 100 | 100 | 100 | 100 | 100 |
| swappiness | 100 | 100 | 100 | 80 | 80 | 60 | 60 |

Если ядро не поддерживает `zstd`, скрипт автоматически выберет первый поддерживаемый алгоритм из списка `zstd`, `lz4`, `lzo-rle`, `lzo`, `zlib`, `842`. Если алгоритм явно задан через `--zram-algo`, неподдерживаемое значение считается ошибкой.

## Параметры командной строки

```
Usage: sudo bash swap-setup.sh [OPTIONS]

Без опций — запускается интерактивный мастер.

Options:
  --ram N             Шаблон для N ГБ RAM (0.5, 1, 2, 3, 4, 6, 8)
  --swapfile-size MB  Размер swap-файла в МБ (переопределяет шаблон)
  --zram-percent N    Размер zram как % от RAM (переопределяет шаблон)
  --zram-algo ALGO    Алгоритм сжатия zram (по умолчанию: zstd)
  --zram-priority N   Приоритет zram swap (по умолчанию: 100)
  --swappiness N      Значение vm.swappiness (переопределяет шаблон)
  --yes               Пропустить запросы подтверждения
  --remove            Удалить swapfile и конфигурацию zram
  --status            Показать текущий статус swap/zram
  -h, --help          Показать справку
```

## Примеры

```bash
# Интерактивный мастер (рекомендуется)
sudo bash swap-setup.sh

# Шаблон для 1 ГБ RAM VPS
sudo bash swap-setup.sh --ram 1

# Шаблон + переопределение параметров
sudo bash swap-setup.sh --ram 1 --zram-percent 150 --swappiness 120

# Полностью ручная настройка через CLI
sudo bash swap-setup.sh --swapfile-size 512 --zram-percent 80 --zram-algo lz4 --swappiness 120

# Автоматический режим без подтверждений (для скриптов/ansible)
sudo bash swap-setup.sh --ram 1 --yes

# Проверка текущего статуса
sudo bash swap-setup.sh --status

# Удаление конфигурации
sudo bash swap-setup.sh --remove
```

## Что проверить после установки

```bash
# zram DISKSIZE должен соответствовать выбранному PERCENT, алгоритм zstd
zramctl

# Должно быть два swap: zram prio 100 → диск prio -2
swapon --show

# Смотрим степень сжатия (самое интересное — DATA / COMPR)
zramctl --output-all

free -h
```

Ожидаемый результат:
- zram DISKSIZE ≈ `RAM * PERCENT / 100` (например, около 1 ГБ для шаблона 1 ГБ RAM)
- Степень сжатия считается как DATA / COMPR ≈ 2.0–3.5 : 1 (чем выше — тем лучше)
- Дисковый swap почти не используется (zram с приоритетом 100 используется первым)
- Скрипт дополнительно проверяет активные приоритеты, zram DISKSIZE, алгоритм, `vm.swappiness` и запись `/etc/fstab`; при несовпадении завершится с ошибкой

## Как это работает

**zram** — сжатая подкачка в оперативной памяти. Работает значительно быстрее дискового swap, т.к. данные сжимаются алгоритмом `zstd` (степень сжатия 2.5–3.5:1) и хранятся прямо в RAM. Важно: `PERCENT` задаёт логический размер zram swap-устройства, а сжатие уменьшает фактическое потребление RAM. Например, при 1 ГБ RAM и `PERCENT=100` система увидит около 1 ГБ zram swap, а не 2–3.5 ГБ.

**Гибридная схема:** система сначала использует zram (приоритет 100), и только когда он заполнится — переходит на дисковый swap (приоритет -2). Это даёт оптимальный баланс скорости и объёма.

## Доступные алгоритмы сжатия

| Алгоритм | Сжатие | Скорость | Рекомендация |
|---|---|---|---|
| **zstd** | ~3:1 | Средняя | Лучший выбор 2025-2026, баланс сжатия и скорости |
| **lz4** | ~2:1 | Очень быстрый | Для слабых CPU, где важна скорость |
| **lzo** | ~2.5:1 | Быстрый | Legacy, сбалансированный |
| **lzo-rle** | ~2.5:1 | Быстрый | Улучшенный lzo |
| **lz4hc** | ~2.5:1 | Средняя | lz4 с лучшим сжатием |
| **zlib** | ~3.5:1 | Медленный | Максимальное сжатие, высокая нагрузка CPU |

## Требования

- Debian / Ubuntu (или производные: Mint, Pop!_OS и т.д.)
- Права root (sudo)
- Пакет `zram-tools` (устанавливается автоматически)
- Достаточно свободного места для staged-создания swap-файла: размер swap-файла + примерно 100 МБ запаса

## Лицензия

MIT
