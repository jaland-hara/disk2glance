"""d2g — orchestrator and receiver for live disk transfers into Cinder volumes.

Orchestrator (one VM per client project, installed with install.sh --role orch):
  d2g setup [--no-local-receiver] [--public-ip IP] [--allow CIDR]... [--fip-pool ID]... [--rx-flavor F] [--rx-key K] [--rx-sg SG]...
  d2g status
  d2g receiver add [--az AZ] [--flavor F] [--fip ID|auto] [--no-wait] | list | delete NAME
  d2g agent add NAME [--path auto|rx-grey|rx-fip|ctl|ctl-grey] [--threads N] | list | revoke | sync | uninstall NAME
  d2g job new AGENT [--receiver rxN] [--type T] [--every SEC] [--no-start] | list | show | sync [--every SEC] JOB
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
    sp.add_parser("status")
    p = sp.add_parser("serve")
    p.add_argument("--workers", type=int)

    p = sp.add_parser("receiver")
    p.add_argument("op", choices=["add", "list", "delete"])
    p.add_argument("name", nargs="?")
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
    if a.cmd != "setup" and not os.path.exists(orch.CONF):
        C.die("not set up: run 'd2g setup' first")
    {"setup": orch.cmd_setup, "status": orch.cmd_status, "serve": orch.cmd_serve, "receiver": orch.cmd_receiver,
     "agent": orch.cmd_agent, "job": orch.cmd_job}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
