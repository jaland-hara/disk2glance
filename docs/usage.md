# disk2glance: инструкция по использованию

Термины (исходная ВМ, новая ВМ, бандл, сборочная ВМ) объяснены в [README](../README.md#термины).

Пошаговая инструкция от установки до новой ВМ: **[quickstart.md](quickstart.md)**. Этот документ —
справочник: файлы, параметры, поведение установщика, ошибки.

## 0. Требования

- Исходная ВМ: Linux x86_64, диск с разделами, ФС ext4/ext3/xfs на разделах или на линейных
  томах LVM, доступ root.
- Исходящий HTTPS с исходной ВМ до Keystone и Glance целевого облака (в VK Cloud это
  `infra.mail.ru:35357` и `infra.mail.ru:9292`).
- Пользователь целевого проекта с правом создавать образы и включённым доступом по API.
  Рекомендуется сервисная учётная запись: [service-accounts.md](service-accounts.md).
- Драйверы virtio в гостевой ОС (есть у любой ВМ, работающей на KVM): [guest-drivers.md](guest-drivers.md).
- Модуль dattobd под ядро исходной ВМ (`uname -r`) в бандле. Список ядер есть в
  [../THIRD_PARTY.md](../THIRD_PARTY.md); если нужного нет, см. [build-modules.md](build-modules.md).

## 1. Файлы конфигурации

Все файлы лежат в `/etc/disk2glance/` (каталог доступен только root). Установщик создаёт их
из шаблонов, если их ещё нет, и никогда не перезаписывает существующие.

| Файл | Формат | Права | Создаётся установщиком | Шаблон |
|---|---|---|---|---|
| `openrc` | строки `export OS_…="…"` | 600 | шаблон с `<…>`, если не передан `--openrc` | [examples/openrc.example](../examples/openrc.example) |
| `props.json` | JSON-объект свойств образа | 644 | пример под ОС исходной ВМ, если не передан `--props` | [examples/props-*.json](../examples/) |
| `disk2glance.conf` | строки `КЛЮЧ=значение` | 644 | всегда, если нет | [examples/disk2glance.conf.example](../examples/disk2glance.conf.example) |

**`openrc`**: переменные OpenStack. Обязательны `OS_AUTH_URL`, `OS_PROJECT_ID`,
`OS_USERNAME`, `OS_PASSWORD` (и обычно `OS_USER_DOMAIN_NAME`, `OS_REGION_NAME`) либо пара
`OS_APPLICATION_CREDENTIAL_ID` + `OS_APPLICATION_CREDENTIAL_SECRET`. Агент выполняет этот файл
как shell-скрипт, поэтому в нём не должно быть интерактивных запросов (`read`), а значения
`<…>` должны быть заменены. Агент проверяет оба условия и права 600.

**`props.json`**: свойства, которые получит образ в Glance. Готовые примеры для проверенных ОС:

| Файл | ОС |
|---|---|
| `props-ubuntu-24.04.json` | Ubuntu 24.04 |
| `props-redos-8.json`, `props-redos-7.3.json` | RED OS 8, 7.3 |
| `props-centos-7.json` | CentOS 7 |
| `props-astra-1.7.json`, `props-astra-1.8.json` | Astra Linux SE 1.7, 1.8 |
| `props-linux.json` | любая другая (минимальный набор) |

Значимые ключи: `os_type`, `os_distro`, `os_version`, `os_admin_user`, `hw_vif_model`,
`hw_qemu_guest_agent` (только если на исходной ВМ есть `qemu-guest-agent`), для UEFI-загрузки
`hw_firmware_type: uefi` и `hw_machine_type: q35`. Свойства конкретного образа целевого облака
можно посмотреть так: `openstack image show <образ> -f json -c properties`.

**`disk2glance.conf`**: значения параметров по умолчанию (`OPENRC`, `PROPS`, `DISK`, `COW_MB`).
Файл не выполняется: читаются только строки `КЛЮЧ=значение` для этих ключей.

**Как сослаться на файлы при запуске.** Без параметров агент берёт файлы из `/etc/disk2glance/`.
Другие пути передаются так: `--openrc FILE`, `--props FILE`, `--config FILE` (файл параметров со
своими `OPENRC=`, `PROPS=` и т. д.). Параметры командной строки важнее файла параметров.
Примеры в [quickstart.md](quickstart.md#где-лежат-файлы-и-как-на-них-сослаться).

## 2. Установщик `install.sh`

```bash
sudo ./install.sh [--openrc FILE] [--props FILE] [--build]
sudo /opt/disk2glance/install.sh --uninstall [--purge]
```

| Параметр | Что делает |
|---|---|
| `--openrc FILE` | скопировать FILE в `/etc/disk2glance/openrc` (600) |
| `--props FILE` | скопировать FILE в `/etc/disk2glance/props.json` |
| `--build` | если готового модуля под ядро нет, собрать его на исходной ВМ (нужны `gcc`, `make`, заголовки ядра) |
| `--uninstall` | удалить агент, модуль, лог; конфигурация остаётся |
| `--purge` | вместе с `--uninstall`: удалить и `/etc/disk2glance` (с паролем) |

**Офлайн** (архив скопирован на исходную ВМ): `tar xzf disk2glance-<версия>.tar.gz && cd disk2glance-<версия> && sudo ./install.sh`.

**Онлайн** (исходная ВМ сама скачивает архив):

```bash
R=https://github.com/jaland-hara/disk2glance/releases/download/v0.6.0
curl -fsSL $R/install.sh -o /tmp/d2g-install.sh
sudo D2G_BUNDLE_URL=$R/disk2glance-0.6.0.tar.gz bash /tmp/d2g-install.sh
```

Если рядом с архивом лежит `<архив>.sha256`, установщик сверяет контрольную сумму.

Что делает установщик:
- проверяет архитектуру, наличие нужных команд, Secure Boot, kernel lockdown, ЗПС Astra;
- ищет модуль под `uname -r`, сверяет sha256 и `vermagic`;
- копирует агент, модуль, утилиты, примеры и сам себя в `/opt/disk2glance`, создаёт ссылки
  `/usr/local/sbin/disk2glance` и `/usr/sbin/disk2glance` (на RHEL-подобных `sudo` не видит
  `/usr/local/sbin`);
- создаёт недостающие файлы конфигурации в `/etc/disk2glance` (см. выше);
- если включён SELinux (RED OS, CentOS), помечает каталог модулей типом `modules_object_t`:
  иначе модуль загружается из обычной сессии, но не из фоновой службы (`--detach`);
- один раз загружает и выгружает модуль для проверки. **В автозагрузку модуль не ставится.**

## 3. Проверка перед переносом

```bash
sudo disk2glance --check
```

Проверка ничего не загружает. Она проверяет учётные данные, доступность Glance, разметку
диска (что пойдёт через снапшот, что будет прочитано как есть) и загрузку модуля. Пример:

```
auth OK, Glance https://infra.mail.ru:9292
  /dev/vda14 start=1048576 size=4194304 fs=none mnt=- -> raw
  /dev/vda15 start=5242880 size=111149056 fs=vfat mnt=/boot/efi -> raw
  /dev/vda16 start=116391936 size=957350400 fs=ext4 mnt=/boot -> snap
  /dev/vda1 start=1074790400 size=20400029184 fs=ext4 mnt=/ -> snap
dattobd 0.12.2 loaded
CHECK OK: image would be 21474836480 bytes raw
```

На CentOS 7 с LVM:

```
  /dev/vda1 start=1048576 size=1073741824 fs=xfs mnt=/boot -> snap
  /dev/vda2 start=1074790400 size=20400046080 -> container for: dm-0 dm-1
    LV centos-root fs=xfs mnt=/ segments=1 -> snap
    LV centos-swap fs=none mnt=- segments=1 -> raw
```

## 4. Перенос

```bash
sudo disk2glance --name myvm-migr-1
```

Приложения можно не останавливать. Если важна согласованность на уровне приложения,
остановите его или переведите в режим только чтения непосредственно перед запуском:
снапшот делается в первые секунды работы агента.

Параметры:

| Параметр | Что делает |
|---|---|
| `--name NAME` | имя образа (по умолчанию `<hostname>-<дата-время>`) |
| `--openrc FILE` | файл учётных данных (по умолчанию `/etc/disk2glance/openrc`) |
| `--props FILE` | свойства образа (по умолчанию `/etc/disk2glance/props.json`) |
| `--config FILE` | файл параметров (по умолчанию `/etc/disk2glance/disk2glance.conf`) |
| `--disk /dev/vdX` | какой диск переносить (по умолчанию `/dev/vda`) |
| `--cow-mb N` | размер COW-файла на каждый снапшот, МиБ (по умолчанию 10% тома). Меньше — короче пауза записи при создании снапшота на нагруженном диске, но COW быстрее переполняется. См. [how-it-works.md](how-it-works.md#пауза-записи-при-создании-снапшота) |
| `--check` | только проверка, без снапшотов и загрузки: конфигурация, вход в облако, разметка, модуль, готовность гостевой ОС к KVM ([guest-drivers.md](guest-drivers.md)), право создавать образы (тестовый пустой образ создаётся и удаляется) |
| `--detach` | запустить отдельным systemd-юнитом (переживает выход из сессии), лог в `/var/log/disk2glance.log` |
| `--keep-module` | не выгружать dattobd после работы |

Во время создания снапшотов **запись приложений на диск на короткое время
приостанавливается**: обычно на 1–3 с, на сильно нагруженных медленных дисках до
десятков секунд. Это свойство механизма заморозки ФС; подробности и замеры в
[how-it-works.md](how-it-works.md#пауза-записи-при-создании-снапшота).

**Рекомендуемый способ — в фоне, отдельным systemd-юнитом:**

```bash
sudo disk2glance --detach --name myvm-migr-1
tail -f /var/log/disk2glance.log
```

Агент перезапускает себя через `systemd-run` и работает вне вашей SSH-сессии, поэтому
переживает выход из неё. Это обязательно на **Astra Linux**: там systemd-logind при выходе
из сессии завершает все её процессы (`KillUserProcesses`), и `nohup` не помогает. Перенос,
запущенный через `nohup`, прервётся, как только закроется SSH. Статус юнита:
`systemctl status disk2glance-<дата-время>`. Остановить перенос можно через
`systemctl stop <юнит>`: агент корректно уберёт снапшоты и выгрузит модуль.

Прогресс (если в системе есть `pv`) пишется в `/run/disk2glance/progress.log`.

Успешный запуск заканчивается так:

```
upload done in 222 s (92 MiB/s): status=active size=21474836480
OK: size and md5 match Glance
6a8a45e5-bac7-4d93-b6ba-f3eabf2a7baf          ← id образа (stdout)
```

Коды выхода: `0` — успех, `1` — ошибка (подробности в stderr), `64` — неверные параметры.
При любом исходе агент удаляет снапшоты и выгружает модуль, если сам его загрузил.

## 5. Создать новую ВМ в целевом облаке

```bash
openstack server create myvm --image <id образа> --flavor <flavor> \
  --boot-from-volume <размер ГБ ≥ размера диска> --network <сеть> \
  --security-group <sg> --key-name <ключ> --availability-zone <AZ>
```

При первой загрузке:
- ext4/xfs проигрывают журнал, СУБД восстанавливаются по своим журналам. На медленных дисках
  восстановление PostgreSQL может занять минуты (end-of-recovery checkpoint).
- cloud-init видит новый instance-id и заново настраивает сеть и SSH-ключи хоста.
  Имя хоста зависит от настроек cloud-init в образе: на Astra 1.8 новая ВМ сохранила имя
  исходной ВМ, на остальных проверенных ОС получила своё имя.
- Сервисы, которые работали на исходной ВМ, стартуют и на новой. Если оба экземпляра не
  должны работать одновременно, остановите исходную ВМ или заранее учтите это в приложении.

Проверить данные на новой ВМ можно скриптом [../verify-clone.sh](../verify-clone.sh); он
написан под тестовую нагрузку, но годится как образец.

## 6. После переноса

На исходной ВМ:

```bash
sudo /opt/disk2glance/install.sh --uninstall --purge
```

Команда удаляет `/opt/disk2glance`, `/etc/disk2glance` (вместе с паролем) и выгружает модуль.
На новой ВМ агент тоже есть, потому что это копия диска исходной ВМ; удалите его там той же командой.

COW-файлы `.datto_d2g`, попавшие в копию, новая ВМ удаляет сама на первой загрузке
(юнит `disk2glance-cowclean.service`, см. [how-it-works.md](how-it-works.md)). Проверить:
`journalctl -b -u disk2glance-cowclean`. Если агент на исходной ВМ был убит `kill -9`
во время снапшота, там мог остаться этот юнит: `install.sh --uninstall` удалит его вместе с
COW-файлами, а если исходную ВМ перезагрузить, юнит удалит их сам.

## Если что-то пошло не так

| Сообщение | Причина и что делать |
|---|---|
| `this account cannot create images in Glance` | у учётной записи нет нужной роли: [service-accounts.md](service-accounts.md) |
| `WARN: virtio_blk is a module but missing from ...` и другие `guest` WARN | гостевая ОС не готова к KVM: [guest-drivers.md](guest-drivers.md) |
| `credentials file ... not found` | нет `/etc/disk2glance/openrc` и не передан `--openrc`: создайте файл ([quickstart.md](quickstart.md), шаг 4) |
| `... asks for input ('read ...')` | openrc скачан из личного кабинета и спрашивает пароль: впишите `export OS_PASSWORD="..."`, удалите строки `read`/`echo` |
| `... is still a template` | в openrc остались значения `<…>`: замените их |
| `... does not set: OS_...` | в openrc нет обязательной переменной |
| `... is not a JSON object` | ошибка в props.json: проверьте запятые и кавычки (`jq . props.json`) |
| `no dattobd module for kernel X` | в бандле нет модуля под это ядро: собрать по [build-modules.md](build-modules.md) или `install.sh --build` |
| `insmod ... failed` | Secure Boot, lockdown или ЗПС Astra (детали в `dmesg`), либо метка SELinux: `ls -Z /opt/disk2glance/modules/*/dattobd.ko` должна показывать `modules_object_t`; переустановите `install.sh` |
| `... holds dm-crypt device` / `only LVM is supported` | раздел зашифрован или под mdraid/multipath: не поддерживается |
| `LV ... has a 'thin-pool' segment` (или raid, striped) | нелинейный LV: не поддерживается |
| `VG spans disks` | группа томов на нескольких дисках: не поддерживается |
| `Keystone auth failed` | неверный `openrc` или нет доступа к `OS_AUTH_URL` |
| `upload failed (image ... left in Glance)` | обрыв сети: удалите незаконченный образ (`openstack image delete`) и запустите заново |
| `MISMATCH` | размер или хеш не совпали: образ не использовать, повторить перенос |
| `another disk2glance is running` | уже идёт другой запуск; `/run/disk2glance/pid` |
| в логе `Завершено` / `Terminated` после выхода из SSH | процесс убит вместе с сессией (Astra, logind `KillUserProcesses`): запускайте с `--detach` |
| `WARN: destroy minor N failed` | снапшот не удалился (например, агент был убит `kill -9`): `sudo /opt/disk2glance/bin/dbdctl destroy N && sudo rmmod dattobd`; незаконченный образ удалить в Glance |
| снапшот в ошибке, в `/proc/datto-info` `"error"` | переполнился COW-файл (за время переноса изменилось больше 10% раздела): повторить при меньшей нагрузке |
