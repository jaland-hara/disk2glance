# disk2glance

Агент для **живого переноса Linux-ВМ в OpenStack** (разделы и линейный LVM) (проверено на VK Cloud). Он
работает внутри переносимой ВМ, делает согласованные снапшоты файловых систем (dattobd) и
одним потоком отправляет весь диск в **Glance** как raw-образ. Приложения на ВМ при этом
продолжают работать. Из образа в целевом облаке создаётся новая ВМ.

Нужны только архив на 2–3 МБ и доступ root. Компилятор, пакеты из репозиториев и
вспомогательная ВМ не нужны. Модуль ядра загружается только на время переноса.

Архив: [Releases](https://github.com/jaland-hara/disk2glance/releases) → `disk2glance-0.3.0.tar.gz`.

```bash
tar xzf disk2glance-0.3.0.tar.gz && cd disk2glance-0.3.0
sudo ./install.sh --openrc openrc --props props.json
sudo disk2glance --check
sudo disk2glance --name myvm-migr-1      # → id образа в Glance
```

## Документация

- [docs/usage.md](docs/usage.md): установка, проверка, перенос, создание ВМ, удаление агента, ошибки.
- [docs/how-it-works.md](docs/how-it-works.md): что агент делает внутри гостевой ОС, что меняет в системе, нагрузка.
- [docs/limitations.md](docs/limitations.md): ограничения, их причины и можно ли их снять.
- [docs/build-modules.md](docs/build-modules.md): сборка модулей dattobd под новые ядра на сборочной ВМ.
- [THIRD_PARTY.md](THIRD_PARTY.md): все сторонние компоненты, откуда взяты, как собраны, лицензии.

## Состав репозитория

| Путь | Что это |
|---|---|
| `disk2glance.sh` | агент (`/opt/disk2glance/bin/disk2glance`) |
| `install.sh` | установщик и деинсталлятор (офлайн из архива или онлайн по URL) |
| `make-bundle.sh` | сборка `dist/disk2glance-<ver>.tar.gz` |
| `publish-release.sh` | публикация бандла в GitHub Releases (токен из `GITHUB_TOKEN`) |
| `build-module.sh` | сборка `dattobd.ko` под заданные ядра на сборочной ВМ |
| `modules/<ядро>/dattobd.ko` | готовые модули (dattobd 0.12.2) |
| `bin/` | статические `dbdctl`, `update-img` (dattobd) и `jq` 1.7.1 |
| `setup-testload.sh`, `verify-clone.sh` | тестовый стенд: PostgreSQL + pgbench + метки времени, проверка клона |
| `examples/` | шаблоны `openrc` и `props.json` |

Учётные данные в репозиторий не попадают. На ВМ они лежат в `/etc/disk2glance/openrc` (600).

## Проверено (VK Cloud, ceph-hdd 20 ГБ, pgbench 40 TPS во время переноса)

| ОС | Ядро | Модуль | Загрузка в Glance | Клон |
|---|---|---|---|---|
| Ubuntu 24.04 | 6.8.0-134-generic | собран на этой ВМ | 222 с, 92 МиБ/с | ✅ PostgreSQL восстановлен, данные целы |
| RED OS 8.0.3 | 6.12.21-1.red80 | собран на этой ВМ | 222 с, 92 МиБ/с | ✅ |
| RED OS 7.3.7 | 6.1.175-1.el7.3 | собран на этой ВМ | 319 с, 64 МиБ/с (параллельно с другой загрузкой) | ✅ |
| RED OS 8.0.3 (чистый образ) | 6.12.92-1.red80 | **собран на другой ВМ**, установлен из бандла 0.2.0 | 262 с, 78 МиБ/с | ✅ |
| RED OS 7.3.7 (чистый образ) | 6.1.175-1.el7.3 | из бандла 0.2.0 | `install` (офлайн и онлайн из GitHub Release), `--check`, `--uninstall` | — |
| **CentOS 7.9, корень на LVM** (`/boot` xfs, `centos-root` xfs, `centos-swap`) | 3.10.0-1160.119.1.el7 | собран без dkms на сборочной ВМ CentOS 7 | 480 с, 42 МиБ/с (pgbench без ограничения скорости) | ✅ LVM и XFS подняты, PostgreSQL 9.2 восстановлен, данные целы |

«✅» означает, что ВМ загрузилась, ext4 проиграла журнал, PostgreSQL догнал WAL, последняя
запись совпадает с моментом снапшота, `amcheck` по индексам чистый, суммы балансов pgbench
сходятся.

## Дальше

Astra Linux 1.7.5 / 1.8.6, Windows 10 (VSS, vTPM/BitLocker),
CI для сборки модулей, режим репликации в тома Cinder. Подробнее в [docs/limitations.md](docs/limitations.md).
