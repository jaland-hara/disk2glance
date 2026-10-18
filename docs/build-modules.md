# Сборка модулей dattobd под новые ядра

Термины (исходная ВМ, сборочная ВМ, бандл) объяснены в [README](../README.md#термины).

Модуль ядра должен в точности соответствовать ядру исходной ВМ (`uname -r`). Собирать его **на
исходной ВМ не нужно**: одна сборочная ВМ того же дистрибутива собирает модули под
любые ядра из его репозиториев, причём само ядро на ней может быть и не установлено.

## Почему это работает

- Модулю нужны заголовки ядра (`kernel-devel` / `linux-headers`) нужной версии.
- dattobd использует часть неэкспортируемых символов ядра. Их адреса скрипт `genconfig.sh`
  при сборке берёт из `System.map` этой версии ядра, а сдвиг KASLR модуль вычисляет сам при
  загрузке. `System.map` одинаков для всех машин с одним и тем же пакетом ядра.
- **Собирать нужно под root.** На RHEL-подобных системах `/boot/System.map-*` доступен
  только root. Под обычным пользователем адреса получатся нулевыми, и на ядрах 6.12 сборка
  завершится ошибкой `modpost: "__get_unmapped_area" undefined`.

## Сборочная ВМ

Это отдельная вспомогательная Linux-ВМ, в переносе она не участвует: на ней только
собирают модули, чтобы добавить их в бандл. Нужна одна ВМ на каждый дистрибутив
(RED OS 7.3, RED OS 8, Ubuntu 24.04, Astra 1.7, …). На неё устанавливаются только средства
сборки:

```bash
# RED OS / CentOS (на CentOS 7 вместо dnf — yum)
sudo dnf -y install gcc make elfutils-libelf-devel git
# Ubuntu / Debian / Astra
sudo apt-get install -y build-essential libelf-dev git
```

## Сборка

```bash
sudo bash build-module.sh 6.12.92-1.red80.x86_64 6.12.101-1.red80.x86_64
```

Для каждой версии скрипт:
1. устанавливает заголовки: `kernel-lt-devel-<ver>` (или `kernel-devel-<ver>`), на Ubuntu
   `linux-headers-<ver>`;
2. копирует `System.map` в `/boot`: на RHEL-подобных берёт его из devel-пакета, на Ubuntu
   извлекает из `linux-modules-<ver>`;
3. если ядро не установлено, создаёт ссылку `/lib/modules/<ver>/build`;
4. копирует исходники во временный каталог, выполняет `genconfig.sh <ver>` и
   `make -C /lib/modules/<ver>/build M=… modules` под root (те же шаги, что в dkms.conf
   dattobd, но без самого dkms: на CentOS 7 его нет в базовых репозиториях);
5. сохраняет `modules/<ver>/dattobd.ko` (без отладочной информации) и `dattobd.ko.sha256`.

Исходники берутся из `/root/dattobd` (тег `v0.12.2`); если их нет, скрипт клонирует репозиторий с GitHub.

Какие ядра есть в репозитории:

```bash
dnf list --showduplicates kernel-lt          # RED OS
apt-cache search linux-headers-6.8.0 | sort  # Ubuntu
```

## Добавить модули в бандл

```bash
scp -r builder:/root/modules/* ./modules/
./make-bundle.sh            # → dist/disk2glance-<версия>.tar.gz + .sha256
```

`make-bundle.sh` проверяет sha256 каждого модуля перед упаковкой.

## Проверка модуля

На любой ВМ, где запущено это ядро (например, на тестовой копии исходной ВМ):

```bash
sudo insmod modules/<ver>/dattobd.ko && cat /proc/datto-info && sudo rmmod dattobd
```

Полная проверка: `install.sh`, `disk2glance --check`, перенос и проверка данных на новой ВМ.

