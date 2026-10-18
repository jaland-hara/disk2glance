# Драйверы гостевой ОС для работы в VK Cloud

Термины (исходная ВМ, новая ВМ, бандл) объяснены в [README](../README.md#термины).

## Кратко

- **disk2glance ничего не устанавливает и не меняет в гостевой ОС.** Образ — это точная копия
  диска исходной ВМ на момент снапшота.
- VK Cloud (как и другие облака OpenStack) запускает ВМ на KVM с устройствами **virtio**:
  диск `virtio-blk` (в системе он виден как `/dev/vda`), сетевая карта `virtio-net`.
  Драйверы virtio входят в стандартное ядро Linux. Отдельные «драйверы VK Cloud» не нужны.
- Если исходная ВМ уже работает на KVM (другое облако OpenStack, Yandex Cloud, Proxmox,
  oVirt), её образ запустится без подготовки: драйверы virtio уже используются.
- Если исходная ВМ работает на **VMware, Hyper-V, Xen** или это физический сервер, перед
  переносом её нужно подготовить: добавить драйверы virtio в initramfs и проверить, что
  диски и сеть не привязаны к старым именам устройств.
- `disk2glance --check` проверяет готовность автоматически и предупреждает о проблемах
  (см. раздел «Что проверяет `disk2glance --check`»).

## Что проверяет `disk2glance --check`

| Проверка | Почему важна | Сообщение при проблеме |
|---|---|---|
| в ядре есть `virtio_pci`, `virtio_blk`, `virtio_net` | без них новая ВМ не увидит диск или сеть | `kernel has no CONFIG_VIRTIO_...` |
| если `virtio_blk` собран модулем, он есть в initramfs | иначе при загрузке не найдётся корневая ФС (`dracut: Could not boot`, `ALERT! UUID=... does not exist`) | `virtio_blk is a module but missing from <initramfs>` |
| в `/etc/fstab` нет `/dev/sdX`, `/dev/xvdX`, `/dev/hdX` | на KVM диски называются `/dev/vdX`, монтирование по старым именам завершится ошибкой | `/etc/fstab uses /dev/sdX-style names` |
| установлен cloud-init | настраивает сеть на новой ВМ; без него настройки, привязанные к старому имени интерфейса или MAC, не заработают | `cloud-init not installed` |
| сеть cloud-init не отключена, либо конфигурация сети не привязана к имени/MAC интерфейса | если в `/etc/cloud/cloud.cfg.d/` задано `network: {config: disabled}`, а netplan/ifcfg называет интерфейс по имени (`enp3s0`) или MAC, на новой ВМ интерфейс будет называться иначе и останется без сети и SSH | `cloud-init network config is disabled and the network config names this VM's NIC(s)` |
| `qemu-guest-agent` установлен, если в `props.json` указано `hw_qemu_guest_agent=yes` | облако будет ожидать гостевой агент | `... qemu-guest-agent is not installed` |

Предупреждения не останавливают перенос, но итог проверки будет
`CHECK OK, BUT see the guest WARN lines above`. Исправьте их до запуска переноса.

На всех проверенных ОС (Ubuntu 24.04, RED OS 7.3 и 8, CentOS 7.9, Astra Linux 1.7.5 и 1.8.6),
запущенных на KVM, проверка проходит без предупреждений.

## Когда и как готовить исходную ВМ (VMware, Hyper-V, Xen, физический сервер)

**Когда:** до запуска `disk2glance`, на работающей исходной ВМ. Образ — копия диска на
момент снапшота, поэтому всё, что нужно новой ВМ, должно быть на диске заранее.
Перезагружать исходную ВМ не нужно: изменения вступят в силу при первой загрузке новой ВМ,
а исходная ВМ продолжит работать на своём гипервизоре как раньше.

### 1. Драйверы virtio в initramfs

RED OS, CentOS, другие RHEL-подобные (dracut):

```bash
echo 'add_drivers+=" virtio_pci virtio_blk virtio_scsi virtio_net "' | sudo tee /etc/dracut.conf.d/virtio.conf
sudo dracut -f /boot/initramfs-$(uname -r).img $(uname -r)
lsinitrd /boot/initramfs-$(uname -r).img | grep -E 'virtio_(blk|pci)'   # должны быть в списке
```

Ubuntu, Debian, Astra Linux (initramfs-tools):

```bash
printf 'virtio_pci\nvirtio_blk\nvirtio_scsi\nvirtio_net\n' | sudo tee -a /etc/initramfs-tools/modules
sudo update-initramfs -u
lsinitramfs /boot/initrd.img-$(uname -r) | grep -E 'virtio_(blk|pci)'
```

Файл в `/etc/dracut.conf.d/` или `/etc/initramfs-tools/modules` нужен, чтобы драйверы попадали
и в initramfs будущих ядер.

### 2. Диски по UUID

Замените в `/etc/fstab` строки вида `/dev/sda1 /data ...` на `UUID=<uuid> /data ...`
(UUID показывает `blkid`). То же для параметра `root=` в загрузчике, если там указано имя
устройства (`grep root= /etc/default/grub /proc/cmdline`).

### 3. Сеть

На новой ВМ сетевой интерфейс будет называться иначе (`eth0`/`ens3` вместо `ens192` на
VMware) и получит другой MAC. Варианты:

- **установить cloud-init** (`dnf install cloud-init` / `apt install cloud-init`): при первой
  загрузке в OpenStack он увидит новый instance-id и настроит сеть по DHCP. Если исходная ВМ
  будет перезагружаться на старом гипервизоре, ограничьте источники данных, чтобы cloud-init
  не ждал облако: `datasource_list: [ OpenStack, ConfigDrive, None ]` в
  `/etc/cloud/cloud.cfg.d/90-datasource.cfg`;
- или заранее добавить конфигурацию DHCP для любого интерфейса (например, в netplan
  `match: {name: "e*"}`), не привязанную к имени и MAC.

Такая ситуация возникает у ВМ из облаков, где провайдер отключает настройку сети cloud-init и
задаёт собственную конфигурацию netplan (пример: ВМ из Cloud.ru с `99-disable-network-config.cfg`
и `01-netconfig.yaml` для `enp3s0`; в VK интерфейс получил имя `enp1s0`). Безопасный вариант —
до переноса добавить на исходной ВМ файл, который не меняет её сеть, но включает сеть на новой ВМ:

```yaml
# /etc/netplan/02-any-nic.yaml (права 600)
network:
  version: 2
  ethernets:
    any-en:
      match:
        name: "en*"
      dhcp4: true
```

Если новая ВМ уже создана без этого файла: отключить её том, подключить его к любой ВМ в том же
облаке, смонтировать корневой раздел, добавить файл в `etc/netplan/`, отключить том и
создать с него ВМ заново.

### 4. Гостевой агент

`qemu-guest-agent` не обязателен для запуска, но с ним облако корректно выключает ВМ и
делает согласованные снапшоты дисков. Его можно установить заранее (на VMware он не будет
запущен) или сразу после переноса на новой ВМ.

### 5. После переноса на новой ВМ

- удалить инструменты старого гипервизора: `open-vm-tools`, VMware Tools, `hyperv-daemons`
  (они не мешают загрузке, но на новой ВМ не нужны и записывают ошибки в журнал);
- удалить агент: `sudo /opt/disk2glance/install.sh --uninstall --purge`.

## Почему агент не подготавливает гостевую ОС

Подготовка меняет цепочку загрузки рабочей системы (initramfs, fstab, сеть). Такие изменения
владелец системы должен вносить осознанно и проверять. Для исходных ВМ на KVM они не
нужны. Поэтому агент только проверяет и предупреждает. Автоматическая подготовка
(например, параметр `--prepare-kvm`, выполняющий шаги 1–3) возможна как отдельная доработка.

## Windows

Перенос Windows пока не поддерживается. Для Windows нужны драйверы virtio-win (диск, сеть,
balloon) до переноса, а также поддержка vTPM и BitLocker. Это запланировано как отдельная
задача.

