# disk2glance: инструкция по использованию

## 0. Что понадобится

- Linux-ВМ, которую нужно перенести (x86_64, диск с разделами, ФС ext4/ext3/xfs прямо на
  разделах или на линейных томах LVM), с доступом root.
- Исходящий HTTPS с этой ВМ до Keystone и Glance целевого облака (в VK Cloud это
  `infra.mail.ru:35357` и `infra.mail.ru:9292`).
- Учётная запись в целевом проекте с правом создавать образы. Лучше отдельная сервисная
  учётка: её пароль будет лежать на переносимой ВМ, пока идёт миграция.
- Бандл `disk2glance-<версия>.tar.gz`, в котором есть модуль под ядро ВМ (`uname -r`).
  Список ядер есть в `modules/` бандла и в [../THIRD_PARTY.md](../THIRD_PARTY.md).
  Если нужного ядра нет, см. [build-modules.md](build-modules.md).

## 1. Подготовить конфигурацию

`openrc`: учётные данные, шаблон в [../examples/openrc.example](../examples/openrc.example).

```bash
export OS_AUTH_URL="https://infra.mail.ru:35357/v3/"
export OS_PROJECT_ID="<id проекта>"
export OS_REGION_NAME="RegionOne"
export OS_USERNAME="<сервисный пользователь>"
export OS_USER_DOMAIN_NAME="<домен пользователя>"
export OS_PASSWORD="<пароль>"
```

`props.json`: свойства будущего образа. Их стоит взять у образа, из которого
создавалась исходная ВМ, или у близкого образа целевого облака:

```bash
openstack image show <похожий образ> -f json -c properties
```

Нужны ключи `os_distro`, `os_type`, `os_admin_user`, `hw_*`; служебные ключи
(`os_hash_*`, `owner_*`, `stores` и т. п.) брать не надо. Пример лежит в
[../examples/props-ubuntu24.json](../examples/props-ubuntu24.json). Для UEFI-ВМ добавьте
`"hw_firmware_type": "uefi"` и `"hw_machine_type": "q35"`.

## 2. Установить агент на переносимую ВМ

**Офлайн** (архив уже на диске ВМ):

```bash
tar xzf disk2glance-0.4.0.tar.gz
cd disk2glance-0.4.0
sudo ./install.sh --openrc /path/to/openrc --props /path/to/props.json
```

**Онлайн** (ВМ сама скачивает архив из GitHub Releases):

```bash
R=https://github.com/jaland-hara/disk2glance/releases/download/v0.4.0
curl -fsSL $R/install.sh -o /tmp/d2g-install.sh
sudo D2G_BUNDLE_URL=$R/disk2glance-0.4.0.tar.gz bash /tmp/d2g-install.sh --openrc /path/to/openrc --props /path/to/props.json
```

Скачать архив для офлайн-установки можно там же: `$R/disk2glance-0.4.0.tar.gz`, контрольная
сумма лежит в `$R/disk2glance-0.4.0.tar.gz.sha256`.

Если рядом лежит `<архив>.sha256`, установщик сверяет контрольную сумму архива.

Что делает установщик:
- проверяет архитектуру, наличие нужных команд, Secure Boot, kernel lockdown, ЗПС Astra;
- ищет модуль под `uname -r`, сверяет sha256 и `vermagic`;
- копирует всё в `/opt/disk2glance`, создаёт ссылки `/usr/local/sbin/disk2glance` и `/usr/sbin/disk2glance` (на RHEL-подобных `sudo` не видит `/usr/local/sbin`);
- один раз загружает и выгружает модуль для проверки. **В автозагрузку модуль не ставится.**

Если готового модуля нет, а на ВМ есть `gcc`, `make` и заголовки ядра, можно собрать модуль
прямо там: `sudo ./install.sh --build`. На рабочих ВМ так обычно не делают, лучше собрать
модуль на сборочной ВМ.

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
| `--disk /dev/vdX` | какой диск переносить (по умолчанию `/dev/vda`) |
| `--cow-mb N` | размер COW-файла на каждый снапшот, МиБ (по умолчанию 10% тома). Меньше — короче пауза записи при создании снапшота на нагруженном диске, но COW быстрее переполняется. См. [how-it-works.md](how-it-works.md#пауза-записи-при-создании-снапшота) |
| `--check` | только проверка, без снапшотов и загрузки |
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

## 5. Создать ВМ в целевом облаке

```bash
openstack server create myvm --image <id образа> --flavor <flavor> \
  --boot-from-volume <размер ГБ ≥ размера диска> --network <сеть> \
  --security-group <sg> --key-name <ключ> --availability-zone <AZ>
```

При первой загрузке:
- ext4/xfs проигрывают журнал, СУБД восстанавливаются по своим журналам. На медленных дисках
  восстановление PostgreSQL может занять минуты (end-of-recovery checkpoint).
- cloud-init видит новый instance-id и заново настраивает сеть и SSH-ключи хоста.
  Имя хоста зависит от настроек cloud-init в образе: на Astra 1.8 клон сохранил имя
  источника, на остальных проверенных ОС получил имя новой ВМ.
- Сервисы, которые работали на источнике, стартуют и на клоне. Если оба экземпляра не
  должны работать одновременно, остановите источник или заранее учтите это в приложении.

Проверить данные клона можно скриптом [../verify-clone.sh](../verify-clone.sh); он
написан под тестовую нагрузку, но годится как образец.

## 6. После переноса

На источнике:

```bash
sudo /path/to/disk2glance-0.4.0/install.sh --uninstall --purge
```

Команда удаляет `/opt/disk2glance`, `/etc/disk2glance` (вместе с паролем) и выгружает модуль.
На клоне агент тоже остался, потому что это копия диска; удалите его там той же командой.

## Если что-то пошло не так

| Сообщение | Причина и что делать |
|---|---|
| `no dattobd module for kernel X` | в бандле нет модуля под это ядро: собрать по [build-modules.md](build-modules.md) или `install.sh --build` |
| `insmod ... failed` | Secure Boot, lockdown или ЗПС Astra; детали в `dmesg` |
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
