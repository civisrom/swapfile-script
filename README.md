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
3. **Создаёт swap-файл** на диске с приоритетом `-2`
4. **Устанавливает и настраивает zram-tools** (сжатая подкачка в RAM, приоритет `100`)
5. **Настраивает `vm.swappiness`** с сохранением после перезагрузки
6. **Добавляет запись в `/etc/fstab`** для автоматического подключения swap после перезагрузки
7. **Выводит итоговую информацию** — `zramctl`, `swapon --show`, `zramctl --output-all`, `free -h`

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
  │  1   │ 1 GB   │  512 MB      │   100%    │ zstd  │   100    │    100     │ << recommended
  │  2   │ 2 GB   │ 1024 MB      │    75%    │ zstd  │   100    │    100     │
  │  3   │ 3 GB   │ 1024 MB      │    60%    │ zstd  │   100    │     80     │
  │  4   │ 4 GB   │ 1536 MB      │    50%    │ zstd  │   100    │     80     │
  │  6   │ 6 GB   │ 2048 MB      │    40%    │ zstd  │   100    │     60     │
  │  8   │ 8 GB   │ 2048 MB      │    25%    │ zstd  │   100    │     60     │
  ├──────┼────────┼──────────────┼───────────┼───────┼──────────┼────────────┤
  │  9   │ Manual input — set each parameter yourself                        │
  └──────┴────────┴──────────────┴───────────┴───────┴──────────┴────────────┘

  Select template (0.5, 1-8, or 9 for manual):
```

### Выбор шаблона (0.5, 1-8)

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
     Recommended: 1024 for 512MB, 512 for 1GB, 1024 for 2GB, 1024-1536 for 3-4GB
     Swapfile size MB [1024]:

  2. Compression algorithm (ALGO)
     Available: zstd | lz4 | lzo | lzo-rle | lz4hc | zlib | 842
     zstd  — best compression ratio (~3:1), moderate CPU (recommended 2025-2026)
     lz4   — fastest, lower compression (~2:1), good for weak CPU
     lzo   — legacy, balanced
     ALGO [zstd]:

  3. zram size as % of RAM (PERCENT)
     Range: 25-200. Recommended: 100 for 1GB, 75 for 2GB, 50-60 for 3-4GB
     PERCENT [75]:
     -> zram will be ~768 MB (75% of 1024 MB)

  4. zram swap priority (PRIORITY)
     Higher = used first. Disk swap has priority -2. Range: 0-32767
     PRIORITY [100]:

  5. vm.swappiness
     How eagerly kernel uses swap. Range: 0-200. For zram: 80-150 recommended
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
  Effective zram capacity after compression (~3:1): ~3072 MB

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
# zram должен быть ~1 ГБ (или больше), алгоритм zstd
zramctl

# Должно быть два swap: zram prio 100 → диск prio -2
swapon --show

# Смотрим степень сжатия (самое интересное — DATA / COMPR)
zramctl --output-all

free -h
```

Ожидаемый результат:
- zram DISKSIZE ≈ 1000–1500 МБ (зависит от настройки)
- COMPR / DATA ≈ 2.0–3.5 : 1 (чем выше — тем лучше)
- Дисковый swap почти не используется (zram с приоритетом 100 используется первым)

## Безопасность и проверки

Скрипт выполняет ряд проверок перед установкой:

- **Валидация параметров** — проверяет что все числовые значения корректны (swapfile-size > 0, swappiness 0-200, priority 0-32767), алгоритм zram из допустимого списка
- **Проверка дискового пространства** — убеждается что на разделе достаточно места для swap-файла (+100 МБ запас)
- **Определение файловой системы** — на btrfs автоматически применяет `chattr +C` (отключение CoW), на ZFS отказывается создавать swapfile (не поддерживается)
- **Бэкап `/etc/fstab`** — создаёт резервную копию перед модификацией (`/etc/fstab.bak.TIMESTAMP`)
- **Проверка конфликтов** — обнаруживает существующий swap, записи в fstab и конфигурацию zramswap
- **Полная очистка при удалении** — `--remove` удаляет swapfile, запись fstab, конфиг zramswap, конфиг swappiness

## Как это работает

**zram** — сжатая подкачка в оперативной памяти. Работает значительно быстрее дискового swap, т.к. данные сжимаются алгоритмом `zstd` (степень сжатия 2.5–3.5:1) и хранятся прямо в RAM. На 1 ГБ RAM при `PERCENT=100` zram может эффективно дать ~2–3.5 ГБ полезного swap-пространства.

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

## Лицензия

MIT
