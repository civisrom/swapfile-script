# swap-setup.sh

Автоматическая настройка гибридной подкачки (swapfile + zram) для Debian/Ubuntu серверов с малым объёмом RAM (1–4 ГБ).

## Быстрая установка

```bash
bash <(wget -qO- https://raw.githubusercontent.com/civisrom/swapfile-script/main/swap-setup.sh)
```

Или с параметрами:

```bash
wget -O swap-setup.sh https://raw.githubusercontent.com/civisrom/swapfile-script/main/swap-setup.sh
sudo bash swap-setup.sh --ram 1
```

## Что делает скрипт

1. **Проверяет** существующую конфигурацию swap (активные устройства, `/etc/fstab`, zramswap) — предотвращает конфликты
2. **Создаёт swap-файл** на диске с приоритетом `-2`
3. **Устанавливает и настраивает zram-tools** (сжатая подкачка в RAM, приоритет `100`)
4. **Настраивает `vm.swappiness`** с сохранением после перезагрузки
5. **Добавляет запись в `/etc/fstab`** для автоматического подключения swap после перезагрузки
6. **Выводит итоговую информацию** — `zramctl`, `swapon --show`, `zramctl --output-all`, `free -h`

## Шаблоны для разных объёмов RAM

| Параметр | 1 ГБ RAM | 2 ГБ RAM | 3 ГБ RAM | 4 ГБ RAM |
|---|---|---|---|---|
| Swap-файл | 768 МБ | 1024 МБ | 1024 МБ | 1536 МБ |
| zram (% от RAM) | 100% | 75% | 60% | 50% |
| Алгоритм | zstd | zstd | zstd | zstd |
| zram приоритет | 100 | 100 | 100 | 100 |
| swappiness | 100 | 100 | 80 | 80 |

## Использование

```
Usage: sudo bash swap-setup.sh [OPTIONS]

Options:
  --ram N             Шаблон для N ГБ RAM (1, 2, 3, 4)
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

### Шаблон для сервера 1 ГБ RAM (рекомендуется)

```bash
sudo bash swap-setup.sh --ram 1
```

Результат:
- swap-файл 768 МБ (`/swapfile`, приоритет -2)
- zram ~1 ГБ (100% RAM, алгоритм zstd, приоритет 100)
- `vm.swappiness=100`

### Шаблон для 2 ГБ RAM

```bash
sudo bash swap-setup.sh --ram 2
```

### Кастомная настройка

```bash
sudo bash swap-setup.sh --swapfile-size 512 --zram-percent 80 --zram-algo lz4 --swappiness 120
```

### Шаблон + переопределение отдельных параметров

```bash
sudo bash swap-setup.sh --ram 1 --zram-percent 150 --swappiness 120
```

### Автоматический режим (без подтверждений)

```bash
sudo bash swap-setup.sh --ram 1 --yes
```

### Проверка текущего статуса

```bash
sudo bash swap-setup.sh --status
```

### Удаление конфигурации

```bash
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

## Как это работает

**zram** — сжатая подкачка в оперативной памяти. Работает значительно быстрее дискового swap, т.к. данные сжимаются алгоритмом `zstd` (степень сжатия 2.5–3.5:1) и хранятся прямо в RAM. На 1 ГБ RAM при `PERCENT=100` zram может эффективно дать ~2–3.5 ГБ полезного swap-пространства.

**Гибридная схема:** система сначала использует zram (приоритет 100), и только когда он заполнится — переходит на дисковый swap (приоритет -2). Это даёт оптимальный баланс скорости и объёма.

## Требования

- Debian / Ubuntu (или производные: Mint, Pop!_OS и т.д.)
- Права root (sudo)
- Пакет `zram-tools` (устанавливается автоматически)

## Лицензия

MIT
