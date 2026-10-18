"""d2g — orchestrator and receiver for live disk transfers into Cinder volumes.

Orchestrator (one VM per client project, installed with install.sh --role orch):
  d2g bootstrap [--public-ip IP] [--ui-allow CIDR]     first start without cloud credentials: web setup wizard
  d2g setup-code                                       a new one-time code for the wizard
  d2g setup [--no-local-receiver] [--public-ip IP] [--ui-allow CIDR]... [--ui-mtls on|off] [--allow CIDR]... [--fip-pool ID]... [--rx-flavor F] [--rx-key K] [--rx-sg SG]...
  d2g status
  d2g admin add|passwd|totp [--off]|delete|cert NAME | list        web UI administrators
  d2g target add|set NAME --mode transfer|receiver --openrc FILE [--az] [--network] [--fip-pool ID]... [--allow CIDR]...
  d2g target list | check NAME | delete NAME           other projects VMs can be moved into
  d2g receiver add [--target T] [--az AZ] [--flavor F] [--fip ID|auto] [--no-wait] | list | delete NAME
  d2g agent add NAME [--path auto|rx-grey|rx-fip|ctl|ctl-grey] [--threads N] | list | revoke | sync | uninstall NAME
  d2g job new AGENT [--target T] [--az AZ] [--receiver rxN] [--type T] [--every SEC] [--no-start] | list | show | sync [--every SEC] JOB
  d2g job finish JOB --flavor F [--network N] [--sg S]... [--key K] [--name VM] | delete JOB [--keep-volume]
Receiver (created by the orchestrator, cloud-init runs install.sh --role rx):
  d2g rx-join | rx-serve | rx-status
"""
import argparse
import os
import sys

from . import common as C


def main():
    ap = argparse.ArgumentParser(prog="d2g", description=__doc__.split("\n")[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    sp = ap.add_subparsers(dest="cmd", required=True)

    p = sp.add_parser("setup")
    p.add_argument("--public-ip")
    p.add_argument("--network")
    p.add_argument("--az")
    p.add_argument("--allow", action="append", default=[], help="CIDR allowed to reach receivers on 443")
    p.add_argument("--fip-pool", action="append", default=[], help="floating IP id the receivers may use")
    p.add_argument("--rx-image")
    p.add_argument("--rx-flavor")
    p.add_argument("--rx-volume-type")
    p.add_argument("--rx-key")
    p.add_argument("--rx-sg", action="append", default=[], help="extra security group for receivers")
    p.add_argument("--no-local-receiver", dest="local_receiver", action="store_false",
                   help="do not run a receiver on the orchestrator VM (receivers only on separate VMs)")
    p.add_argument("--ui-allow", action="append", default=[], help="CIDR allowed to open the web UI")
    p.add_argument("--ui-mtls", choices=["on", "off"], help="require an admin client certificate for the web UI")
    p.add_argument("--replace-lists", action="store_true", help="--allow/--fip-pool/--ui-allow replace the lists")
    p.add_argument("--max-volumes", type=int, help="volumes per receiver")
    p.add_argument("--finish-setup", action="store_true", help=argparse.SUPPRESS)
    p = sp.add_parser("bootstrap")
    p.add_argument("--public-ip")
    p.add_argument("--ui-allow", action="append", default=[])
    sp.add_parser("setup-code")
    sp.add_parser("status")
    p = sp.add_parser("admin")
    p.add_argument("op", choices=["add", "list", "passwd", "totp", "delete", "cert"])
    p.add_argument("name", nargs="?")
    p.add_argument("--password-stdin", action="store_true")
    p.add_argument("--off", action="store_true", help="totp: turn it off")
    p.add_argument("--out", help="cert: .p12 file to write")
    p = sp.add_parser("serve")
    p.add_argument("--workers", type=int)

    p = sp.add_parser("target")
    p.add_argument("op", choices=["add", "set", "list", "check", "delete"])
    p.add_argument("name", nargs="?")
    p.add_argument("--mode", choices=["transfer", "receiver"])
    p.add_argument("--openrc", help="openrc of the target project's service account")
    p.add_argument("--title")
    p.add_argument("--az")
    p.add_argument("--network")
    p.add_argument("--rx-image")
    p.add_argument("--rx-flavor")
    p.add_argument("--rx-volume-type")
    p.add_argument("--rx-key")
    p.add_argument("--allow", action="append", default=[])
    p.add_argument("--fip-pool", action="append", default=[])
    p.add_argument("--vm-sg", action="append", default=[])
    p.add_argument("--max-volumes", type=int)
    p.add_argument("--replace-lists", action="store_true")
    p.add_argument("--force", action="store_true", help="save even if the checks fail")

    p = sp.add_parser("receiver")
    p.add_argument("op", choices=["add", "list", "delete"])
    p.add_argument("name", nargs="?")
    p.add_argument("--target", default="home", help="project: home or a target in receiver mode")
    p.add_argument("--az")
    p.add_argument("--flavor")
    p.add_argument("--fip", help="floating IP id from the pool, or 'auto'")
    p.add_argument("--no-wait", action="store_true")

    p = sp.add_parser("agent")
    p.add_argument("op", choices=["add", "list", "revoke", "sync", "uninstall"])
    p.add_argument("name", nargs="?")
    p.add_argument("--path", default="auto", choices=["auto", "rx-grey", "rx-fip", "ctl", "ctl-grey"])
    p.add_argument("--threads", type=int, default=8)

    p = sp.add_parser("job")
    p.add_argument("op", choices=["new", "list", "show", "sync", "finish", "delete"])
    p.add_argument("arg", nargs="?")
    p.add_argument("--target", default="home", help="project to move the VM into: home or a target")
    p.add_argument("--receiver")
    p.add_argument("--az")
    p.add_argument("--type")
    p.add_argument("--size-gb", type=int)
    p.add_argument("--every", type=int)
    p.add_argument("--no-start", action="store_true")
    p.add_argument("--flavor")
    p.add_argument("--network")
    p.add_argument("--sg", action="append")
    p.add_argument("--key")
    p.add_argument("--name")
    p.add_argument("--force", action="store_true")
    p.add_argument("--keep-volume", action="store_true")

    p = sp.add_parser("rx-join")
    p.add_argument("--join-file", default=os.path.join(C.ETC, "join.json"))
    p = sp.add_parser("rx-serve")
    p.add_argument("--workers", type=int)
    sp.add_parser("rx-status")

    a = ap.parse_args()
    os.umask(0o077)
    if a.cmd == "target":
        from . import orch as O, targets as T
        O.db_init()
        return T.cmd_target(a)
    if a.cmd in ("receiver", "agent") and a.op not in ("list",) and a.op != "add" and not a.name:
        C.die("name required")
    if a.cmd == "agent" and a.op == "add" and not a.name:
        C.die("agent name required")
    if a.cmd == "job" and a.op not in ("list",) and not a.arg:
        C.die("job (or agent for 'new') required")
    if a.cmd == "job" and a.op == "finish" and not a.flavor:
        C.die("--flavor required")

    if a.cmd.startswith("rx-"):
        from . import recv
        {"rx-join": recv.cmd_join, "rx-serve": recv.cmd_serve, "rx-status": recv.cmd_status}[a.cmd](a)
        return
    from . import orch
    if a.cmd not in ("setup", "bootstrap") and not os.path.exists(orch.CONF):
        C.die("not set up: run 'd2g setup' first")
    if a.cmd in ("bootstrap", "setup-code"):
        return {"bootstrap": orch.cmd_bootstrap, "setup-code": orch.cmd_setup_code}[a.cmd](a)
    if a.cmd == "admin":
        from . import ui
        orch.db_init()
        return ui.cmd_admin(a)
    {"setup": orch.cmd_setup, "status": orch.cmd_status, "serve": orch.cmd_serve, "receiver": orch.cmd_receiver,
     "agent": orch.cmd_agent, "job": orch.cmd_job}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
