#!/bin/sh
exec /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C /usr/bin/perl - "$0" "$@" <<'PERL'
use strict;
use warnings;
use Cwd qw(realpath);
use Digest::SHA ();
use Fcntl qw(:DEFAULT :flock :mode);
use File::Find qw(find);
use JSON::PP qw(decode_json encode_json);

my $tool_dir = '/Library/SlateHopOperator';
my $tool = "$tool_dir/operator-admin.sh";
my $root = '/Library/SlateHopHost';
my $bundle = "$root/RustDesk.app";
my $host = "$bundle/Contents/MacOS/RustDesk";
my $service = "$bundle/Contents/MacOS/service";
my $daemon_label = 'com.slatehop.managed-host.service';
my $agent_label = 'com.slatehop.managed-host.server';
my $max_ms = 253402300799999;

sub fail { die "SlateHop operator: $_[0]\n"; }

sub capture {
    my ($lock, @command) = @_;
    my $pid = open my $pipe, '-|';
    defined $pid or fail('could not start a local check');
    if (!$pid) {
        open STDIN, '<', '/dev/null' and open STDERR, '>', '/dev/null' or exit 126;
        # The host retains the same lock if the SSH session and this parent disappear.
        if (defined $lock) {
            defined fcntl($lock, F_SETFD, 0) or exit 126;
        }
        exec { $command[0] } @command or exit 127;
    }
    my $text = '';
    while (1) {
        my $size = read($pipe, my $chunk, 4096);
        if (!defined $size || (defined $lock && length($text) + $size > 16384)) {
            close $pipe;
            return (1, '');
        }
        last unless $size;
        $text .= $chunk;
    }
    close $pipe;
    return ($?, $text);
}

sub output {
    my ($status, $text) = capture(undef, @_);
    $status == 0 or fail("local verification failed: $_[0]");
    return $text;
}

sub protected {
    my ($path, $directory) = @_;
    my @st = lstat $path;
    @st && ($directory ? S_ISDIR($st[2]) : S_ISREG($st[2]))
        && $st[4] == 0 && !($st[2] & 06022) && ($directory || $st[3] == 1)
        or fail("unprotected object: $path");
    my $listing = output('/bin/ls', '-lde', $path);
    $listing =~ /\A[^\r\n]{10}[ @][^\r\n]*\n\z/ or fail("unexpected ACL or listing: $path");
    return @st;
}

sub open_protected {
    my ($path, $mode) = @_;
    my @entry = protected($path, 0);
    sysopen my $file, $path, $mode | O_NOFOLLOW | O_NONBLOCK or fail("cannot open $path");
    my @opened = stat $file;
    @opened && $opened[0] == $entry[0] && $opened[1] == $entry[1]
        && $opened[2] == $entry[2] && $opened[3] == 1 && $opened[4] == 0
        or fail("protected object changed: $path");
    binmode $file;
    return $file;
}

sub verify_link {
    my ($entry, $device) = @_;
    my @resolved = split m{/}, substr($entry, length($bundle) + 1);
    my @pending = (pop @resolved);
    my $links = 0;
    while (@pending) {
        my $part = shift @pending;
        next if $part eq '' || $part eq '.';
        if ($part eq '..') {
            @resolved or fail('bundle link leaves the protected bundle');
            pop @resolved;
            next;
        }
        my $path = join('/', $bundle, @resolved, $part);
        my @st = lstat $path;
        @st && $st[0] == $device && $st[4] == 0 or fail('unprotected bundle link target');
        if (S_ISLNK($st[2])) {
            my $target = readlink $path;
            defined $target && $target !~ m{\A/|[\x00-\x1f\x7f]} && ++$links <= 40
                or fail('invalid bundle link');
            unshift @pending, split m{/}, $target;
        } else {
            push @resolved, $part;
        }
    }
    my $target = realpath($entry);
    @resolved && defined $target && $target eq join('/', $bundle, @resolved)
        or fail('unresolved bundle link');
}

sub verify_bundle {
    my ($release, $device) = @_;
    local $SIG{__WARN__} = sub { fail('could not inspect the complete protected bundle'); };
    find({ no_chdir => 1, wanted => sub {
        my $entry = $File::Find::name;
        $entry !~ /[\x00-\x1f\x7f]/ or fail('invalid bundle path');
        my @st = lstat $entry;
        @st && $st[0] == $device && $st[4] == 0 or fail('unprotected bundle entry');
        if (S_ISLNK($st[2])) {
            verify_link($entry, $device);
        } else {
            protected($entry, S_ISDIR($st[2]));
        }
    } }, $bundle);
    for my $item ([$host, 'host_sha256'], [$service, 'service_sha256']) {
        my ($path, $key) = @$item;
        my $canonical = realpath($path);
        defined $canonical && $canonical eq $path && -x $path or fail('noncanonical managed executable');
        my $file = open_protected($path, O_RDONLY);
        (stat $file)[2] & 0100 or fail('managed executable lacks owner execute permission');
        Digest::SHA->new(256)->addfile($file)->hexdigest eq $release->{$key}
            or fail('managed executable does not match the installed release');
    }
    my $requirement = '=anchor apple generic and identifier "com.carriez.rustdesk"'
        . ' and certificate 1[field.1.2.840.113635.100.6.2.6] exists'
        . ' and certificate leaf[field.1.2.840.113635.100.6.1.13] exists'
        . qq( and certificate leaf[subject.OU] = "$release->{team}");
    output('/usr/bin/codesign', '--verify', '--strict', '--deep', '--all-architectures',
        '-R', $requirement, $bundle);
}

sub read_release {
    my $file = open_protected("$root/release.json", O_RDONLY);
    my $size = -s $file;
    $size > 0 && $size <= 4096 or fail('invalid managed release record');
    my $count = read($file, my $text, $size);
    defined $count && $count == $size or fail('could not read the complete managed release record');
    my $release = eval { decode_json($text) };
    ref($release) eq 'HASH' && ($release->{team} // '') =~ /\A[A-Z0-9]{10}\z/
        && ($release->{uid} // '') =~ /\A[1-9][0-9]{0,9}\z/ && $release->{uid} < 4294967295
        && ($release->{port} // '') =~ /\A[1-9][0-9]{0,4}\z/ && $release->{port} <= 65535
        or fail('invalid managed release identity');
    for my $key (qw(archive_sha256 host_sha256 service_sha256 admin_sha256)) {
        ($release->{$key} // '') =~ /\A[0-9a-f]{64}\z/ or fail('invalid managed release digest');
    }
    return $release;
}

sub running_job {
    my ($target, $definition, $executable, $uid) = @_;
    my $info = output('/bin/launchctl', 'print', $target);
    $info =~ /^\s*path = \Q$definition\E\s*$/m && $info =~ /^\s*program = \Q$executable\E\s*$/m
        && $info =~ /^\s*state = running\s*$/m && $info =~ /^\s*pid = ([1-9][0-9]*)\s*$/m
        or fail("managed launchd job is not running from the approved path: $target");
    my $pid = $1;
    my $actual_uid = output('/bin/ps', '-p', $pid, '-o', 'uid=');
    $actual_uid =~ /\A\s*\Q$uid\E\s*\z/ or fail('serving process UID is unexpected');
    my @st = protected($executable, 0);
    my $mappings = output('/usr/sbin/lsof', '-nP', '-a', '-p', $pid, '-d', 'txt', '-Ffin');
    for my $mapping (split /^f/m, $mappings) {
        return $pid if $mapping =~ /^n\Q$executable\E$/m && $mapping =~ /^i\Q$st[1]\E$/m;
    }
    fail('loaded executable does not match the pinned installation');
}

sub serving_identity {
    my ($release) = @_;
    my $uid = $release->{uid};
    my @console = stat '/dev/console';
    @console && $console[4] == $uid or fail('the recorded serving UID is not the current Aqua user');
    my $daemon = running_job("system/$daemon_label", "/Library/LaunchDaemons/$daemon_label.plist", $service, 0);
    my $server = running_job("gui/$uid/$agent_label", "/Library/LaunchAgents/$agent_label.plist", $host, $uid);
    my $port = $release->{port};
    my $listeners = output('/usr/sbin/lsof', '-nP', "-iTCP:$port", '-sTCP:LISTEN', '-Fp');
    my @owners = $listeners =~ /^p([1-9][0-9]*)$/mg;
    @owners == 1 && $owners[0] == $server or fail('the recorded direct listener is not owned by the managed server');
    return "$daemon:$uid:$server";
}

sub valid_ms {
    my ($value) = @_;
    return defined $value && !ref($value) && $value =~ /\A(?:0|[1-9][0-9]{0,14})\z/ && $value <= $max_ms;
}

sub arguments {
    my ($operation, @values) = @_;
    return ('--rental-admin-status') if $operation eq 'status' && !@values;
    my %flags = (renew => '--rental-admin-set-expiry', reset => '--rental-admin-new-password');
    if (exists $flags{$operation} && @values == 1 && valid_ms($values[0]) && $values[0] > 0) {
        return ($flags{$operation}, $values[0]);
    }
    fail('usage: operator-admin.sh status | renew UTC_MILLISECONDS | reset UTC_MILLISECONDS');
}

sub validated_reply {
    my ($operation, $expiry, $text) = @_;
    my $reply = eval { decode_json($text) };
    ref($reply) eq 'HASH' or fail('invalid reply from managed host');
    my %allowed = map { $_ => 1 } qw(state now_ms valid_from_ms valid_until_ms);
    $allowed{password} = 1 if $operation eq 'reset';
    !grep { !$allowed{$_} } keys %$reply or fail('unexpected field in the host reply');
    my ($state, $now, $from, $until) = @{$reply}{qw(state now_ms valid_from_ms valid_until_ms)};
    defined $state && !ref($state) && valid_ms($now)
        && exists $reply->{valid_from_ms} && exists $reply->{valid_until_ms}
        or fail('invalid state or time in the host reply');
    my $recovery = $operation eq 'status' && $state eq 'recovery_required';
    if (!defined $from && !defined $until) {
        ($operation eq 'status' && ($state eq 'unconfigured' || $recovery))
            or fail('missing rental window from the host');
    } else {
        valid_ms($from) && valid_ms($until) && $from < $until or fail('invalid rental window from the host');
        my $expected = $now < $from ? 'pending' : $now < $until ? 'active' : 'expired';
        $state eq $expected || $recovery or fail('inconsistent rental state from the host');
    }
    if ($operation ne 'status') {
        defined $until && $until == $expiry or fail('host did not confirm the requested expiration');
    }
    if ($operation eq 'reset') {
        my $password = $reply->{password};
        defined $password && !ref($password) && $password =~ /\A[!-~]{1,128}\z/
            or fail('host did not return a valid new credential');
    }
    return $reply;
}

sub main {
    my $invocation = shift @ARGV // '';
    my $operation = shift @ARGV // '';
    my @args = arguments($operation, @ARGV);
    $^O eq 'darwin' && $< == 0 && $> == 0 or fail('requires administrator privileges on macOS');
    $invocation eq $tool or fail('requires the reviewed operator script at its fixed protected path');
    !-t STDOUT or fail('use the administrator SSH connection without a remote terminal');
    chdir '/' or fail('cannot enter trusted working directory');
    protected($_, 1) for ('/', '/Library', $tool_dir);
    protected($tool, 0);
    lstat $root or fail('a protected managed installation and its release record are required');
    my ($device) = protected($root, 1);
    my ($library_device) = protected('/Library', 1);
    $device == $library_device && output('/bin/df', '-Pl', $root) =~ /\n[^\r\n]+\n/
        or fail('managed host root must be on the local Library volume');

    my $lock = open_protected("$root/.lifecycle.lock", O_RDWR);
    ((stat $lock)[2] & 0777) == 0600 or fail('unexpected lifecycle lock mode');
    flock $lock, LOCK_EX | LOCK_NB or fail('another managed host operation is in progress');
    lstat "$root/.transaction" and fail('an incomplete managed installation requires recovery');
    $!{ENOENT} or fail('could not establish managed installation state');
    my $release = read_release();
    verify_bundle($release, $device);
    my $before = serving_identity($release);
    my ($status, $text) = capture($lock, $host, @args);
    $status == 0 or fail('host command failed. Check status before trying another mutation');
    my $after = eval { serving_identity($release) };
    defined $after && $after eq $before
        or fail('serving identity changed. The operation may have applied. Check status before retrying');
    local $| = 1;
    print encode_json(validated_reply($operation, $args[1], $text)), "\n"
        or fail('could not return the operator reply. Check status before retrying');
}

main();
PERL
