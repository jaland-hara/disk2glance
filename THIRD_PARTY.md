# Сторонние компоненты и их происхождение

Всё, что входит в бандл `disk2glance-<версия>.tar.gz`, и всё, на что агент опирается в
гостевой ОС. Для каждого компонента указано, откуда он взят, как собран и под какой лицензией.

## 1. Что поставляется в бандле

| Файл в бандле | Что это | Источник | Как получен | Лицензия |
|---|---|---|---|---|
| `disk2glance.sh` → `/opt/disk2glance/bin/disk2glance` | агент | этот репозиторий | — | проект |
| `install.sh` | установщик | этот репозиторий | — | проект |
| `modules/<ядро>/dattobd.ko` | модуль ядра dattobd 0.12.2 (снапшоты блочных устройств с COW) | https://github.com/datto/dattobd, тег `v0.12.2`, коммит `90cde6e468052fadbf4dabe5bd3cafc0a2fe700f` | собран DKMS **под root** на сборочной ВМ того же дистрибутива (см. таблицу ниже), отладочная информация удалена `strip --strip-debug` | GPL-2.0-only |
| `bin/dbdctl` | утилита управления снапшотами dattobd | тот же тег dattobd (`app/dbdctl.c` + `lib/libdattobd.c`) | собрана **статически** на Ubuntu 24.04: `gcc -O2 -static -I lib -I src app/dbdctl.c lib/libdattobd.a`, gcc 13.3.0, glibc 2.39 | dbdctl — GPL-2.0, libdattobd — LGPL-2.1 |
| `bin/update-img` | утилита dattobd для инкрементального обновления образа (зарезервирована под режим репликации, сейчас агентом не вызывается) | тот же тег (`utils/update-img.c`) | собрана статически, как `dbdctl` | GPL-2.0 |
| `bin/jq` | jq 1.7.1, разбор JSON (Keystone/Glance API) | https://github.com/jqlang/jq/releases/tag/jq-1.7.1, файл `jq-linux-amd64` | скачан с официального релиза, sha256 сверен с `sha256sum.txt` релиза | MIT |
| `src/dattobd/` | исходники dattobd того же тега | архив `https://github.com/datto/dattobd/archive/refs/tags/v0.12.2.tar.gz` | без изменений | GPL-2.0 / LGPL-2.1 |

Статические бинарники `dbdctl` и `update-img` содержат части glibc (LGPL-2.1). Исходники
dattobd лежат в бандле (`src/dattobd`), исходники glibc 2.39 доступны в архиве Ubuntu
(`apt-get source glibc` на Ubuntu 24.04), поэтому перелинковка возможна.

Контрольные суммы (sha256) бинарников версии 0.2.0:

```
ebb6a2bd548a9375604edbb08da9bbc275def7bb2cc139d0ed695b6194f68790  bin/dbdctl
13220b80a7aca5fdf9b00c44a57518c27c3448b95a35df07685ec3361c97f20e  bin/update-img
5942c9b0934e510ee61eb3e30273f1b3fe2590df93933a93d7c58b81d19c8ff5  bin/jq
```

У каждого модуля рядом лежит `dattobd.ko.sha256`. `install.sh` проверяет его и сверяет
`vermagic` модуля с `uname -r`.

### Готовые модули (бандл 0.2.0)

| Ядро | Дистрибутив | Где собран | Пакеты для сборки (из репозиториев дистрибутива) |
|---|---|---|---|
| `6.8.0-134-generic` | Ubuntu 24.04 | на самой ВМ с этим ядром (exp-src01) | `build-essential`, `dkms`, `linux-headers-6.8.0-134-generic` — archive.ubuntu.com |
| `6.12.21-1.red80.x86_64` | RED OS 8 | на ВМ с этим ядром (exp-redos8) | `gcc`, `make`, `dkms`, `elfutils-libelf-devel`, `kernel-lt-devel-6.12.21-1.red80` — репозитории RED OS (`base`, `updates`) |
| `6.12.92-1.red80.x86_64` | RED OS 8 | на сборочной ВМ RED OS 8 (кросс-сборка) | то же + `kernel-lt-devel-6.12.92-1.red80` |
| `6.12.101-1.red80.x86_64` | RED OS 8 | на сборочной ВМ RED OS 8 (кросс-сборка, ядро на ВМ не установлено) | то же + `kernel-lt-devel-6.12.101-1.red80` |
| `6.1.175-1.el7.3.x86_64` | RED OS 7.3 | на ВМ с этим ядром (exp-redos73) | `gcc`, `make`, `dkms`, `elfutils-libelf-devel`, `kernel-lt-devel-6.1.175-1.el7.3` — репозитории RED OS (`base`, `updates`, `kernels6`) |
| `6.1.180-1.el7.3.x86_64` | RED OS 7.3 | на сборочной ВМ RED OS 7.3 (кросс-сборка) | то же + `kernel-lt-devel-6.1.180-1.el7.3` |

Модули подписаны локальными ключами DKMS сборочных ВМ, но `strip` удаляет подпись. При
выключенном Secure Boot это не важно. При включённом модуль нужно подписать ключом, который
зарегистрирован в MOK целевой ВМ.

## 2. Что агент берёт из гостевой ОС (в бандл не входит)

| Команда | Пакет (Debian/Ubuntu · RHEL/RED OS) | Зачем |
|---|---|---|
| `bash` ≥ 4.2 | bash | сам агент |
| `curl` | curl | Keystone и Glance API, потоковая загрузка (`PUT -T -`, chunked) |
| `dd`, `tee`, `md5sum`, `sha512sum`, `sort`, `date` | coreutils | чтение диска по смещениям, контрольные суммы |
| `findmnt`, `flock` | util-linux | точки монтирования и ФС разделов, защита от параллельного запуска |
| `insmod`, `rmmod`, `modinfo` | kmod | загрузка и выгрузка dattobd |
| `pv` (необязательно) | pv | прогресс загрузки (`/run/disk2glance/progress.log`) |

Всё это есть в минимальных установках Ubuntu, Debian, RED OS, CentOS 7 и Astra Linux.

## 3. Что используется только при сборке (на сборочной ВМ, не на мигрируемой)

- `gcc`, `make`, `dkms`, `elfutils-libelf-devel` / `libelf-dev`.
- Заголовки ядра: `kernel-lt-devel-<ver>` (RED OS), `kernel-devel-<ver>` (CentOS), `linux-headers-<ver>` (Ubuntu/Astra).
- `System.map` нужного ядра. На RHEL-подобных системах он входит в `kernel-*-devel`
  (`/usr/src/kernels/<ver>/System.map`), на Ubuntu — в `linux-modules-<ver>`.
  Скрипт `build-module.sh` извлекает его сам.
