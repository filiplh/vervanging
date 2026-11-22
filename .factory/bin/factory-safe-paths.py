"""Safe paths for the machine state under ~/.factory: one copy, loaded by the tools that keep such state (factory-usage
for the usage ledger, factory.py for the machine's slots) with importlib, as they load factory-doctor.py.

The rule: every folder and file of the state must be a real folder or a regular file (no symbolic link, no hard-linked
file), owned by you, and writable by nobody else (no group or other write bit). Each is opened below the one before by
descriptor (O_NOFOLLOW, relative to the parent's descriptor) and checked on the open descriptor, so a swap between the
check and the use cannot redirect a read or a write. HOME itself is trusted as your home. Missing folders and files
are created that way (0700 and 0600).

    open_home()                                     HOME, as a folder descriptor
    open_at(parent, name, where, folder, create,    name below the parent descriptor, checked; None when missing
            write=False, exclusive=False)            and not created. exclusive: create it new (O_EXCL), and let
                                                     FileExistsError through when the name is taken
    check_fd(fd, where, folder)                     the checks on an open descriptor

Every refusal is Unsafe(message): `where` is how the message names the path (such as "~/.factory/usage"). Standard
library only; Python 3.8 and later, macOS and Linux. It never reads a credential and prints nothing.
"""

import errno
import os
import stat


class Unsafe(Exception):
    """A path that is not safe to use, or that cannot be opened; str() is the message."""


def unsafe(where, why, folder):
    return Unsafe("%s is not safe to use: %s; it must be a real %s of yours that only you can write. Nothing more was "
                  "read or written; fix it by hand" % (where, why, "folder" if folder else "file"))


def check_fd(fd, where, folder):
    """The checks on an open descriptor: type, owner, no group or other write, one link for a file."""
    st = os.fstat(fd)
    if folder and not stat.S_ISDIR(st.st_mode):
        raise unsafe(where, "not a folder", folder)
    if not folder and not stat.S_ISREG(st.st_mode):
        raise unsafe(where, "not a regular file", folder)
    if st.st_uid != os.geteuid():
        raise unsafe(where, "owned by another user", folder)
    if st.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        raise unsafe(where, "writable by %s" % ("others" if st.st_mode & stat.S_IWOTH else "its group"), folder)
    if not folder and st.st_nlink != 1:
        raise unsafe(where, "a hard-linked file", folder)
    return st


def open_home(what="the machine state (~/.factory)"):
    home = os.environ.get("HOME")
    if not home or not os.path.isabs(home):
        raise Unsafe("HOME is not set to a folder, so %s cannot be found" % what)
    try:
        return os.open(home, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    except OSError as e:
        raise Unsafe("cannot open HOME (%s)" % e.__class__.__name__)


def open_at(parent, name, where, folder, create, write=False, exclusive=False):
    """Open name below the parent descriptor without following a link; None when missing and not created."""
    base = os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK
    if folder:
        flags = base | os.O_RDONLY | os.O_DIRECTORY
    else:
        flags = base | ((os.O_RDWR | os.O_APPEND) if write else os.O_RDONLY) | (os.O_CREAT if create else 0)
        flags |= os.O_EXCL if create and exclusive else 0
    for attempt in (1, 2):
        try:
            fd = os.open(name, flags, 0o600, dir_fd=parent)
            break
        except FileNotFoundError:
            if not create:
                return None
            if folder and attempt == 1:
                try:
                    os.mkdir(name, 0o700, dir_fd=parent)
                except FileExistsError:
                    pass
                continue
            raise Unsafe("cannot create %s" % where)
        except FileExistsError:
            if exclusive:
                raise
            raise Unsafe("cannot open %s (FileExistsError)" % where)
        except OSError as e:
            if e.errno in (errno.ELOOP, errno.EMLINK, errno.ENOTDIR):
                # Refused either way; the lstat (by descriptor, no follow) only names the reason.
                try:
                    link = stat.S_ISLNK(os.stat(name, dir_fd=parent, follow_symlinks=False).st_mode)
                except OSError:
                    link = e.errno != errno.ENOTDIR
                raise unsafe(where, "a symbolic link" if link else "not a folder", folder)
            raise Unsafe("cannot open %s (%s)" % (where, e.__class__.__name__))
    try:
        check_fd(fd, where, folder)
    except BaseException:
        os.close(fd)
        raise
    return fd
