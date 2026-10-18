# Сторонние компоненты и их происхождение

Всё, что входит в бандл `disk2glance-<версия>.tar.gz`, и всё, на что агент опирается в
гостевой ОС исходной ВМ. Термины объяснены в [README](README.md#термины). Для каждого компонента указано, откуда он взят, как собран и под какой лицензией.

## 1. Что поставляется в бандле

| Файл в бандле | Что это | Источник | Как получен | Лицензия |
|---|---|---|---|---|
| `disk2glance.sh` → `/opt/disk2glance/bin/disk2glance` | агент | этот репозиторий | — | проект |
| `install.sh` | установщик | этот репозиторий | — | проект |
| `modules/<ядро>/dattobd.ko` | модуль ядра dattobd 0.12.2 (снапшоты блочных устройств с COW) с доработкой «набор снапшотов» | https://github.com/datto/dattobd, тег `v0.12.2`, коммит `90cde6e468052fadbf4dabe5bd3cafc0a2fe700f`, плюс доработки `patches/dattobd-hold-thaw.patch` (набор снапшотов: параметры `hold_thaw`, `release_held`, `hold_timeout_ms`; `src/tracer.c`, `src/tracer.h`, `src/module_control.c`) и `patches/dattobd-write-zeroes.patch` (исправление проверки `REQ_OP_WRITE_ZEROES` на ядрах 6.0+; `src/bio_helper.c`, `src/tracer.c`) | с 0.8.0 — с наложенными доработками; собран **под root** на сборочной ВМ того же дистрибутива (см. таблицу ниже), отладочная информация удалена `strip --strip-debug` | GPL-2.0-only |
| `bin/dbdctl` | утилита управления снапшотами dattobd | тот же тег dattobd (`app/dbdctl.c` + `lib/libdattobd.c`) | собрана **статически** на Ubuntu 24.04: `gcc -O2 -static -I lib -I src app/dbdctl.c lib/libdattobd.a`, gcc 13.3.0, glibc 2.39 | dbdctl — GPL-2.0, libdattobd — LGPL-2.1 |
| `bin/update-img` | утилита dattobd для инкрементального обновления образа (агентом не вызывается) | тот же тег (`utils/update-img.c`) | собрана статически, как `dbdctl` | GPL-2.0 |
| `bin/jq` | jq 1.7.1, разбор JSON (Keystone/Glance API) | https://github.com/jqlang/jq/releases/tag/jq-1.7.1, файл `jq-linux-amd64` | скачан с официального релиза, sha256 сверен с `sha256sum.txt` релиза | MIT |
| `src/dattobd/` | исходники dattobd того же тега, из которых собраны модули | архив `https://github.com/datto/dattobd/archive/refs/tags/v0.12.2.tar.gz` | с наложенными доработками из `src/patches/` (файлы доработок лежат рядом) | GPL-2.0 / LGPL-2.1 |

Серверный бандл `d2g-server-<версия>.tar.gz` (оркестратор и приёмник, вариант 2) написан на Python
и использует только стандартную библиотеку. Из стороннего в нём одна библиотека:

| Файл | Что это | Источник | Как получен | Лицензия |
|---|---|---|---|---|
| `d2g/static/vendor/qrcode.js` | QR Code Generator for JavaScript 1.4.4 (Kazuhiko Arase): QR-код для TOTP в мастере установки | https://www.npmjs.com/package/qrcode-generator, файл `qrcode.js` версии 1.4.4 | без изменений, лицензия в заголовке файла | MIT |

На ВМ оркестратора из пакетов дистрибутива ставятся `nginx-core` и `libnginx-mod-stream` (BSD-2-Clause).

Статические бинарники `dbdctl` и `update-img` содержат части glibc (LGPL-2.1). Исходники
dattobd входят в бандл (`src/dattobd`), исходники glibc 2.39 доступны в архиве Ubuntu
(`apt-get source glibc` на Ubuntu 24.04), поэтому перелинковка возможна.

Контрольные суммы (sha256) бинарников (не менялись с 0.2.0):

```
ebb6a2bd548a9375604edbb08da9bbc275def7bb2cc139d0ed695b6194f68790  bin/dbdctl
13220b80a7aca5fdf9b00c44a57518c27c3448b95a35df07685ec3361c97f20e  bin/update-img
5942c9b0934e510ee61eb3e30273f1b3fe2590df93933a93d7c58b81d19c8ff5  bin/jq
```

Рядом с каждым модулем находится `dattobd.ko.sha256`. `install.sh` проверяет его и сверяет
`vermagic` модуля с `uname -r`.

### Готовые модули в бандле

| Ядро | Дистрибутив | Где собран (0.8.0, `build-module.sh` с `patches/`) | Пакеты для сборки (из репозиториев дистрибутива) |
|---|---|---|---|
| `6.8.0-134-generic` | Ubuntu 24.04 | на ВМ Ubuntu 24.04, где запущено это ядро; набор снапшотов и исправление `WRITE_ZEROES` проверены на нём | `build-essential`, `libelf-dev`, `linux-headers-6.8.0-134-generic` — archive.ubuntu.com |
| `6.8.0-146-generic` | Ubuntu 24.04 | там же, кросс-сборка | то же + `linux-headers-6.8.0-146-generic` (+ `System.map` из `linux-modules-6.8.0-146-generic`) |
| `5.15.0-181-generic` | Ubuntu 22.04 | на сборочной ВМ Ubuntu 22.04 (ядро 5.15.0-185), кросс-сборка | `build-essential`, `libelf-dev`, `linux-headers-5.15.0-181-generic` — archive.ubuntu.com |
| `5.15.0-185-generic` | Ubuntu 22.04 | там же, запущенное ядро; набор проверен | то же + `linux-headers-5.15.0-185-generic` |
| `6.12.21-1.red80.x86_64` | RED OS 8 | на сборочной ВМ RED OS 8 (ядро 6.12.92), кросс-сборка | `gcc`, `make`, `elfutils-libelf-devel`, `kernel-lt-devel-6.12.21-1.red80` — репозитории RED OS (`base`, `updates`) |
| `6.12.92-1.red80.x86_64` | RED OS 8 | там же, запущенное ядро; набор и исправление `WRITE_ZEROES` проверены | то же + `kernel-lt-devel-6.12.92-1.red80` |
| `6.12.101-1.red80.x86_64` | RED OS 8 | там же, кросс-сборка | то же + `kernel-lt-devel-6.12.101-1.red80` |
| `6.1.175-1.el7.3.x86_64` | RED OS 7.3 | на сборочной ВМ RED OS 7.3, запущенное ядро; набор и исправление `WRITE_ZEROES` проверены | `gcc`, `make`, `elfutils-libelf-devel`, `kernel-lt-devel-6.1.175-1.el7.3` — репозитории RED OS (`base`, `updates`, `kernels6`) |
| `6.1.180-1.el7.3.x86_64` | RED OS 7.3 | там же, кросс-сборка | то же + `kernel-lt-devel-6.1.180-1.el7.3` |
| `6.1.50-1-generic` | Astra Linux SE 1.7.5 | на сборочной ВМ Astra 1.7.5, запущенное ядро; набор и исправление `WRITE_ZEROES` проверены | `build-essential`, `libelf-dev`, `linux-headers-6.1.50-1-generic` — замороженный репозиторий Astra 1.7.5 (`download.astralinux.ru/astra/frozen/1.7_x86-64/1.7.5/repository-base`) |
| `6.1.158-1-generic` | Astra Linux SE 1.8.5 | на сборочной ВМ Astra 1.8.5 (образ VK `alse-1.8.5-base`), запущенное ядро; набор и исправление `WRITE_ZEROES` проверены | `build-essential` (gcc 12), `libelf-dev`, `linux-headers-6.1.158-1-generic` — замороженный репозиторий Astra 1.8.5 (`download.astralinux.ru/astra/frozen/1.8_x86-64/1.8.5/main-repository`) |
| `6.1.166-1-generic` | Astra Linux SE 1.8.6 | на той же ВМ после установки ядра 1.8.6, запущенное ядро; набор и исправление `WRITE_ZEROES` проверены | то же + `linux-image-6.1.166-1-generic`, `linux-headers-6.1.166-1-generic` — замороженный репозиторий Astra 1.8.6 (`…/1.8_x86-64/1.8.6/main-repository`) |
| `4.18.0-553.137.1.el8_10.x86_64` | AlmaLinux 8.10 | на сборочной ВМ AlmaLinux 8.10 (образ VK `almalinux-8.10`), запущенное ядро; набор и исправление `WRITE_ZEROES` проверены | `gcc`, `make`, `elfutils-libelf-devel`, `kernel-devel-4.18.0-553.137.1.el8_10` — репозитории AlmaLinux 8 (`baseos`, `appstream`) |
| `4.18.0-553.174.1.el8_10.x86_64` | AlmaLinux 8.10 | там же, кросс-сборка | `gcc`, `make`, `elfutils-libelf-devel`, `kernel-devel-4.18.0-553.174.1.el8_10` — репозитории AlmaLinux 8 (`baseos`, `appstream`) |
| `5.14.0-687.19.1.el9_8.x86_64` | AlmaLinux 9.8 | на сборочной ВМ AlmaLinux 9.8 (образ VK `almalinux-9.8`), запущенное ядро; набор и исправление `WRITE_ZEROES` проверены | `gcc`, `make`, `elfutils-libelf-devel`, `kernel-devel-5.14.0-687.19.1.el9_8` — репозитории AlmaLinux 9 (`baseos`, `appstream`) |
| `5.14.0-687.57.1.el9_8.x86_64` | AlmaLinux 9.8 | там же, кросс-сборка | `gcc`, `make`, `elfutils-libelf-devel`, `kernel-devel-5.14.0-687.57.1.el9_8` — репозитории AlmaLinux 9 (`baseos`, `appstream`) |
| `6.12.0-211.28.1.el10_2.x86_64` | AlmaLinux 10.2 | на сборочной ВМ AlmaLinux 10.2 (образ VK `almalinux-10.2`), запущенное ядро; набор и исправление `WRITE_ZEROES` проверены | `gcc`, `make`, `elfutils-libelf-devel`, `kernel-devel-6.12.0-211.28.1.el10_2` — репозитории AlmaLinux 10 (`baseos`, `appstream`) |
| `6.12.0-211.65.1.el10_2.x86_64` | AlmaLinux 10.2 | там же, кросс-сборка | `gcc`, `make`, `elfutils-libelf-devel`, `kernel-devel-6.12.0-211.65.1.el10_2` — репозитории AlmaLinux 10 (`baseos`, `appstream`) |
| `3.10.0-1160.119.1.el7.x86_64` | CentOS 7.9 | на сборочной ВМ CentOS 7, запущенное ядро; механизм набора проверен | `gcc`, `make`, `elfutils-libelf-devel`, `kernel-devel-3.10.0-1160.119.1.el7` — репозитории CentOS 7 (`updates`, vault.centos.org) |

Модули подписаны локальными ключами DKMS сборочных ВМ, но `strip` удаляет подпись. При
выключенном Secure Boot это не важно. При включённом модуль нужно подписать ключом, который
зарегистрирован в MOK исходной ВМ (модуль загружается именно там).

## 2. Что агент использует из гостевой ОС исходной ВМ (в бандл не входит)

| Команда | Пакет (Debian/Ubuntu · RHEL/RED OS) | Зачем |
|---|---|---|
| `bash` ≥ 4.2 | bash | сам агент |
| `curl` | curl | Keystone и Glance API, потоковая загрузка (`PUT -T -`, chunked) |
| `dd`, `tee`, `md5sum`, `sha512sum`, `sort`, `date` | coreutils | чтение диска по смещениям, контрольные суммы |
| `findmnt`, `flock` | util-linux | точки монтирования и ФС разделов, защита от параллельного запуска |
| `dmsetup` (только при LVM) | device-mapper (устанавливается вместе с lvm2) | таблица сегментов LV: где экстенты LV расположены на диске |
| `sync` | coreutils | запись изменённых данных из кэша на диск перед снапшотом |
| `systemd-run` (только с `--detach`) | systemd | запуск агента отдельным юнитом вне сессии пользователя |
| `systemd-detect-virt` (необязательно) | systemd | какой гипервизор сейчас (только для сообщения в `--check`) |
| `lsinitrd` / `lsinitramfs` (необязательно) | dracut / initramfs-tools | есть ли драйверы virtio в initramfs |
| `pgrep` | procps | остановка своего конвейера (dd, curl) при сигнале |
| `stat` | coreutils | проверка прав файла с учётными данными |
| `semanage`, `restorecon` или `chcon` (только при включённом SELinux, вызывает установщик) | policycoreutils | метка `modules_object_t` для каталога модулей |
| `insmod`, `rmmod`, `modinfo` | kmod | загрузка и выгрузка dattobd |
| `pv` (необязательно) | pv | прогресс загрузки (`/run/disk2glance/progress.log`) |

Всё это есть в минимальных установках Ubuntu, Debian, RED OS, CentOS 7 и Astra Linux.

## 3. Что используется только при сборке (на сборочной ВМ, не на исходной)

- `gcc`, `make`, `elfutils-libelf-devel` / `libelf-dev`, `git`. dkms не нужен: `build-module.sh`
  сам выполняет те же шаги (`genconfig.sh` под root и kbuild).
- Заголовки ядра: `kernel-lt-devel-<ver>` (RED OS), `kernel-devel-<ver>` (CentOS), `linux-headers-<ver>` (Ubuntu/Astra).
- `System.map` нужного ядра. На RHEL-подобных системах он входит в `kernel-*-devel`
  (`/usr/src/kernels/<ver>/System.map`), на Ubuntu — в `linux-modules-<ver>`.
  Скрипт `build-module.sh` извлекает его сам.
