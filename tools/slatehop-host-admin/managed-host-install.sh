#!/bin/sh
exec /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C /usr/bin/perl - "$@" <<'PERL'
use strict;
use warnings;
use Cwd qw(realpath);
use Digest::SHA ();
use Fcntl qw(:DEFAULT :flock :mode);
use File::Basename qw(basename dirname);
use File::Copy qw(copy);
use File::Find qw(find);
use File::Path qw(remove_tree);
use File::Temp qw(tempdir tempfile);
use JSON::PP qw(decode_json);

my $root = '/Library/SlateHopHost';
my $transaction = "$root/.transaction";
my $complete = "$root/.complete";
my $receipt = 'release.json';
my $host = 'RustDesk.app';
my $admin = 'SlateHop Host Admin.app';
my $host_exe = 'Contents/MacOS/RustDesk';
my $service = 'Contents/MacOS/service';
my $admin_exe = 'Contents/MacOS/SlateHopHostAdmin';
my $host_id = 'com.carriez.rustdesk';
my $admin_id = 'com.slatehop.host-admin';
my $daemon_label = 'com.slatehop.managed-host.service';
my $agent_label = 'com.slatehop.managed-host.server';
my @legacy_labels = ('com.carriez.RustDesk_service', 'com.carriez.RustDesk_server');
my $daemon_plist = "/Library/LaunchDaemons/$daemon_label.plist";
my $agent_plist = "/Library/LaunchAgents/$agent_label.plist";
my $launchctl = '/bin/launchctl';
my $json = JSON::PP->new->utf8->canonical;

sub fail { die "SlateHop managed host: $_[0]\n"; }
sub present {
    return 1 if lstat $_[0];
    return 0 if $!{ENOENT};
    fail("cannot establish filesystem state: $_[0]");
}

# List-form execution keeps package paths, launchd output and release metadata out of shell syntax.
sub capture {
    my ($with_errors, @command) = @_;
    my $input = ref($with_errors) ? $with_errors : undef;
    my $pid = open my $pipe, '-|';
    defined $pid or fail('cannot start a system tool');
    if (!$pid) {
        open STDIN, '<&', $input or exit 126 if $input;
        open STDERR, $with_errors && !$input ? '>&STDOUT' : '>/dev/null' or exit 126;
        exec { $command[0] } @command or exit 127;
    }
    my $output = do { local $/; <$pipe> // '' };
    close $pipe;
    return ($?, $output);
}

sub output {
    my ($status, $text) = capture(0, @_);
    $status == 0 or fail("system tool failed: $_[0]");
    return $text;
}

sub run {
    my ($command, @arguments) = @_;
    system { $command } $command, @arguments;
    $? == 0 or fail("system tool failed: $command");
}

sub no_acl {
    my ($path) = @_;
    my $listing = output('/bin/ls', '-lde', $path);
    # -e prints ACLs on their own lines. All paths checked here exclude control characters.
    $listing =~ /\A[^\r\n]+\n\z/ or fail("unexpected ACL or directory listing: $path");
}

sub protected {
    my ($path, $directory) = @_;
    my @st = lstat $path;
    @st && ($directory ? S_ISDIR($st[2]) : S_ISREG($st[2]))
        && $st[4] == 0 && !($st[2] & 06022) && ($directory || $st[3] == 1)
        or fail("unprotected filesystem object: $path");
    no_acl($path);
    return @st;
}

sub same_entries {
    my ($directory, @expected) = @_;
    opendir my $dir, $directory or fail("cannot read $directory");
    my @entries = sort grep { $_ ne '.' && $_ ne '..' } readdir $dir;
    join("\0", @entries) eq join("\0", sort @expected) or fail("unknown contents: $directory");
}

sub verify_bundle_link {
    my ($bundle, $entry, $device) = @_;
    my @resolved = split m{/}, substr($entry, length($bundle) + 1);
    my @pending = (pop @resolved);
    my $links = 0;
    while (@pending) {
        my $component = shift @pending;
        next if $component eq '' || $component eq '.';
        if ($component eq '..') {
            @resolved or fail("bundle link leaves its root: $entry");
            pop @resolved;
            next;
        }
        my $path = join('/', $bundle, @resolved, $component);
        my @st = lstat $path;
        @st && $st[0] == $device && $st[4] == 0 or fail("unprotected bundle link target: $entry");
        if (S_ISLNK($st[2])) {
            my $target = readlink $path;
            defined $target && $target !~ m{\A/} && ++$links <= 40
                or fail("invalid bundle link: $entry");
            unshift @pending, split m{/}, $target;
        } else {
            push @resolved, $component;
        }
    }
    @resolved or fail("bundle link resolves to its root: $entry");
    my $target = realpath($entry);
    defined $target && $target eq join('/', $bundle, @resolved) or fail("unresolved bundle link: $entry");
}

sub bundle_tree {
    my ($path) = @_;
    my ($device) = protected($path, 1);
    local $SIG{__WARN__} = sub { fail("cannot inspect the complete bundle: $path"); };
    find({ no_chdir => 1, wanted => sub {
        my $entry = $File::Find::name;
        $entry !~ /[\x00-\x1f\x7f]/ or fail('control character in bundle path');
        my @st = lstat $entry;
        @st && $st[0] == $device && $st[4] == 0 or fail("unprotected bundle entry: $entry");
        if (S_ISLNK($st[2])) {
            verify_bundle_link($path, $entry, $device);
        } else {
            protected($entry, S_ISDIR($st[2]));
        }
    } }, $path);
}

sub sha256 {
    my ($path) = @_;
    sysopen my $file, $path, O_RDONLY | O_NOFOLLOW or fail("cannot read $path");
    binmode $file;
    return Digest::SHA->new(256)->addfile($file)->hexdigest;
}

sub write_record {
    my ($path, $record) = @_;
    sysopen my $file, $path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600
        or fail("cannot create $path");
    print {$file} $json->encode($record) or fail("cannot write $path");
    close $file or fail("cannot seal $path");
}

sub read_record {
    my ($path) = @_;
    my @st = protected($path, 0);
    $st[7] > 0 && $st[7] <= 4096 or fail("invalid transaction record: $path");
    open my $file, '<', $path or fail("cannot read $path");
    my $record = eval { local $/; decode_json(<$file>) };
    ref($record) eq 'HASH' or fail("invalid transaction record: $path");
    return $record;
}

sub release_record {
    my ($record) = @_;
    ref($record) eq 'HASH' && ($record->{team} // '') =~ /\A[A-Z0-9]{10}\z/
        && ($record->{uid} // '') =~ /\A[1-9][0-9]{0,9}\z/ && $record->{uid} < 4294967295
        && ($record->{port} // '') =~ /\A[1-9][0-9]{0,4}\z/ && $record->{port} <= 65535
        or fail('invalid managed release identity');
    for my $key (qw(archive_sha256 host_sha256 service_sha256 admin_sha256)) {
        ($record->{$key} // '') =~ /\A[0-9a-f]{64}\z/ or fail("invalid managed release digest: $key");
    }
    return $record;
}

sub verify_code {
    my ($path, $team, $identifier) = @_;
    my $req = 'anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists'
        . ' and certificate leaf[field.1.2.840.113635.100.6.1.13] exists'
        . qq( and certificate leaf[subject.OU] = "$team");
    $req .= qq( and identifier "$identifier") if defined $identifier;
    run('/usr/bin/codesign', '--verify', '--strict', '--deep', '--all-architectures', '-R', "=$req", $path);
}

sub plist {
    my ($path) = @_;
    protected($path, 0);
    my $dictionary = eval { decode_json(output('/usr/bin/plutil', '-convert', 'json', '-o', '-', $path)) };
    ref($dictionary) eq 'HASH' or fail("unreadable plist: $path");
    return $dictionary;
}

sub verify_privileged_profile {
    my ($path) = @_;
    my ($status, $details) = capture(1, '/usr/bin/codesign', '--display', '--verbose=4', $path);
    $status == 0 && $details =~ /^CodeDirectory[^\r\n]+\bflags=0x([0-9a-fA-F]+)/m && (hex($1) & 0x10000)
        or fail("Hardened Runtime is required for the privileged executable: $path");
    my $entitlements = output('/usr/bin/codesign', '--display', '--entitlements', ':-', $path);
    return if $entitlements !~ /\S/;
    my ($file, $name) = tempfile('.slatehop-entitlements.XXXXXXXX', DIR => $root, UNLINK => 1);
    unlink $name or fail('cannot anonymize the staged signature entitlements');
    print {$file} $entitlements or fail('cannot stage signature entitlements');
    seek $file, 0, 0 or fail('cannot read staged signature entitlements');
    my ($convert, $document) = capture($file, '/usr/bin/plutil', '-convert', 'json', '-o', '-', '-');
    my $values = eval { decode_json($document) };
    $convert == 0 && ref($values) eq 'HASH' or fail('unreadable signature entitlements');
    for my $key ('com.apple.security.get-task-allow', 'com.apple.security.cs.disable-library-validation',
        'com.apple.security.cs.allow-dyld-environment-variables') {
        !$values->{$key} or fail("development entitlement is incompatible with privileged execution: $key");
    }
}

sub pair_identity {
    my ($directory, $team) = @_;
    my $host_app = "$directory/$host";
    my $admin_app = "$directory/$admin";
    bundle_tree($host_app);
    bundle_tree($admin_app);
    for my $exe ("$host_app/$host_exe", "$host_app/$service", "$admin_app/$admin_exe") {
        my @st = protected($exe, 0);
        $st[2] & 0100 or fail("unusable executable: $exe");
        realpath($exe) eq $exe or fail("noncanonical executable: $exe");
    }
    verify_code($host_app, $team, $host_id);
    verify_code("$host_app/$service", $team, undef);
    verify_code($admin_app, $team, $admin_id);
    verify_privileged_profile($host_app);
    verify_privileged_profile("$host_app/$service");
    my %digests = (
        host_sha256 => sha256("$host_app/$host_exe"),
        service_sha256 => sha256("$host_app/$service"),
        admin_sha256 => sha256("$admin_app/$admin_exe"),
    );
    my $host_info = plist("$host_app/Contents/Info.plist");
    my $admin_info = plist("$admin_app/Contents/Info.plist");
    ($host_info->{CFBundleExecutable} // '') eq basename($host_exe)
        && ($admin_info->{CFBundleExecutable} // '') eq basename($admin_exe)
        && ($admin_info->{SlateHopTrustedHostSHA256} // '') eq $digests{host_sha256}
        or fail('the approved administration app does not pin this signed host');
    return %digests;
}

sub verify_pair {
    my ($directory, $identity) = @_;
    release_record($identity);
    my %actual = pair_identity($directory, $identity->{team});
    for my $kind (keys %actual) {
        $actual{$kind} eq $identity->{$kind} or fail("signed release digest changed: $kind");
    }
}

sub verify_plist {
    my ($path, $label) = @_;
    my $is_daemon = $label eq $daemon_label;
    my %expected = (
        Label => $label, AssociatedBundleIdentifiers => $host_id,
        WorkingDirectory => "$root/$host/Contents/MacOS/", RunAtLoad => JSON::PP::true,
        ThrottleInterval => 1,
    );
    if ($is_daemon) {
        $expected{KeepAlive} = JSON::PP::true;
        $expected{ProgramArguments} = ["$root/$host/$service"];
        $expected{StandardErrorPath} = '/var/log/rustdesk_service.err';
        $expected{StandardOutPath} = '/var/log/rustdesk_service.out';
    } else {
        $expected{KeepAlive} = { SuccessfulExit => JSON::PP::false, AfterInitialDemand => JSON::PP::false };
        $expected{ProgramArguments} = ["$root/$host/$host_exe", '--server'];
        $expected{LimitLoadToSessionType} = ['LoginWindow', 'Aqua'];
        $expected{ProcessType} = 'Interactive';
    }
    $json->encode(plist($path)) eq $json->encode(\%expected)
        or fail("unexpected or legacy launchd definition: $path");
}

sub domain_info {
    my ($target) = @_;
    my ($status, $info) = capture(1, $launchctl, 'print', $target);
    return $info if $status == 0;
    return undef if $info =~ /Could not find (?:service|domain)\b/i;
    fail("cannot establish launchd state: $target");
}

sub job_info {
    my ($domain, $label, $definition, $executable) = @_;
    my $info = domain_info("$domain/$label");
    return undef unless defined $info;
    $info =~ /^\s*path = \Q$definition\E\s*$/m && $info =~ /^\s*program = \Q$executable\E\s*$/m
        or fail("same-label job points outside the managed release: $domain/$label");
    return $info;
}

sub host_domains {
    my ($uid) = @_;
    my (undef, undef, undef, undef, $console_uid) = stat '/dev/console';
    defined $console_uid && $console_uid == $uid && defined domain_info("gui/$uid")
        or fail("the approved serving user has no active Aqua domain: $uid");
    my %domains = map { $_ => 1 } ('system', 'user/0', "user/$uid", "gui/$uid");
    my $loginwindow = domain_info('user/0');
    if (defined $loginwindow && $loginwindow =~ /^\s*asid = ([0-9]+)\s*$/m) {
        $domains{"login/$1"} = 1;
    }
    for my $line (split /\n/, output('/usr/bin/who')) {
        my ($name) = split /\s+/, $line;
        next unless defined $name && length $name;
        my (undef, undef, $other_uid) = getpwnam($name);
        next unless defined $other_uid;
        $domains{"user/$other_uid"} = $domains{"gui/$other_uid"} = 1;
        if ($other_uid != $uid && defined domain_info("gui/$other_uid")) {
            fail('another Aqua domain is active');
        }
    }
    my (undef, undef, undef, undef, undef, undef, undef, $home) = getpwuid($uid);
    defined $home && $home =~ m{\A/} or fail('cannot establish serving user home');
    for my $label ($agent_label, $daemon_label, @legacy_labels) {
        present("$home/Library/LaunchAgents/$label.plist") and fail('a per-user launch definition conflicts');
    }
    return sort keys %domains;
}

sub no_other_jobs {
    my ($uid, $managed) = @_;
    for my $path ("/Library/LaunchDaemons/$legacy_labels[0].plist", "/Library/LaunchAgents/$legacy_labels[1].plist") {
        present($path) and fail("legacy launchd definition requires separate migration: $path");
    }
    for my $domain (host_domains($uid)) {
        for my $label ($daemon_label, $agent_label, @legacy_labels) {
            next if $managed && (($domain eq 'system' && $label eq $daemon_label)
                || ($domain eq "gui/$uid" && $label eq $agent_label));
            defined domain_info("$domain/$label") and fail("unexpected launchd registration: $domain/$label");
        }
    }
    my $processes = output('/bin/ps', '-Aww', '-o', 'comm=');
    $processes !~ m{^\s*/Applications/[^\n]*/Contents/MacOS/service\s*$}m
        or fail('an unmanaged host service is running under /Applications');
    my $commands = output('/bin/ps', '-Aww', '-o', 'args=');
    $commands !~ m{^\s*/Applications/[^\n]*/Contents/MacOS/RustDesk\s+--server(?:\s|$)}m
        or fail('an unmanaged host server is running under /Applications');
}

sub managed_jobs {
    my ($uid) = @_;
    return (
        ['system', $daemon_label, $daemon_plist, "$root/$host/$service", 0],
        ["gui/$uid", $agent_label, $agent_plist, "$root/$host/$host_exe", $uid],
    );
}

sub job_pid {
    my ($info) = @_;
    return undef unless defined $info && $info =~ /^\s*pid = ([1-9][0-9]*)\s*$/m;
    return $1;
}

sub process_matches {
    my ($pid, $uid, $executable) = @_;
    my ($status, $line) = capture(0, '/bin/ps', '-p', $pid, '-o', 'uid=');
    return 0 unless $status == 0 && $line =~ /\A\s*\Q$uid\E\s*\z/;
    my @executable = lstat $executable;
    return 0 unless @executable && S_ISREG($executable[2]);
    my ($result, $files) = capture(0, '/usr/sbin/lsof', '-nP', '-a', '-p', $pid, '-d', 'txt', '-Ffin');
    return 0 unless $result == 0;
    # Field output groups the inode and name by text mapping, regardless of field order.
    for my $mapping (split /^f/m, $files) {
        return 1 if $mapping =~ /^n\Q$executable\E$/m && $mapping =~ /^i\Q$executable[1]\E$/m;
    }
    return 0;
}

sub listener_owned_by {
    my ($port, $pid) = @_;
    my ($status, $items) = capture(0, '/usr/sbin/lsof', '-nP', "-iTCP:$port", '-sTCP:LISTEN', '-Fp');
    return 0 unless $status == 0;
    my @owners = $items =~ /^p([1-9][0-9]*)$/mg;
    return @owners == 1 && $owners[0] == $pid;
}

sub wait_ready {
    my ($identity) = @_;
    my @jobs = managed_jobs($identity->{uid});
    my $last;
    for (1..30) {
        my @pids;
        for my $job (@jobs) {
            my $info = job_info(@{$job}[0..3]);
            my $pid = job_pid($info);
            push @pids, $pid if defined $pid && $info =~ /^\s*state = running\s*$/m
                && process_matches($pid, $job->[4], $job->[3]);
        }
        if (@pids == 2 && listener_owned_by($identity->{port}, $pids[1])) {
            my $measured = join(':', @pids);
            if (defined $last && $last eq $measured) {
                my ($status, $reply) = capture(0, "$root/$host/$host_exe", '--rental-admin-status');
                my $check = eval { decode_json($reply) };
                return if $status == 0 && ref($check) eq 'HASH'
                    && ($check->{state} // '') =~ /\A(?:unconfigured|pending|active|expired|recovery_required)\z/
                    && !exists $check->{password};
            }
            $last = $measured;
        } else {
            undef $last;
        }
        sleep 1;
    }
    fail('daemon, serving UID, direct listener or verified local management IPC did not become ready');
}

sub stop_jobs {
    my ($uid) = @_;
    my @registered;
    for my $job (reverse managed_jobs($uid)) {
        my ($domain, $label, $definition, $executable, $job_uid) = @$job;
        my $info = job_info($domain, $label, $definition, $executable);
        next unless defined $info;
        my $pid = job_pid($info);
        if (defined $pid && !process_matches($pid, $job_uid, $executable) && kill(0, $pid)) {
            fail("job PID does not match the managed executable: $domain/$label");
        }
        push @registered, ["$domain/$label", $pid];
    }
    for my $job (@registered) {
        my ($target, $pid) = @$job;
        capture(0, $launchctl, 'bootout', $target);
        for (1..30) {
            last if !defined domain_info($target) && (!defined $pid || !kill(0, $pid));
            sleep 1;
        }
        !defined domain_info($target) && (!defined $pid || !kill(0, $pid))
            or fail("job did not stop: $target");
    }
    require_no_managed_processes();
}

sub require_no_managed_processes {
    my $commands = output('/bin/ps', '-Aww', '-o', 'args=');
    $commands !~ m{^\s*\Q$root/$host/$host_exe\E\s+--server(?:\s|$)}m
        && $commands !~ m{^\s*\Q$root/$host/$service\E(?:\s|$)}m
        or fail('a managed host process is still running outside its launchd registrations');
}

sub prior_job_state {
    my ($action, $identity) = @_;
    if ($action eq 'rollback') {
        my @jobs = map { job_info(@{$_}[0..3]) } managed_jobs($identity->{uid});
        if (!defined $jobs[0] && !defined $jobs[1]) {
            require_no_managed_processes();
            return (0, 0, 0);
        }
        for my $info (@jobs) {
            defined $info && defined job_pid($info) && $info =~ /^\s*state = running\s*$/m
                or fail('rollback requires a fully running service pair or both jobs unregistered');
        }
    }
    wait_ready($identity);
    return (1, 1, 1);
}

sub stage_archive {
    my ($archive, $expected, $target) = @_;
    sysopen my $input, $archive, O_RDONLY | O_NOFOLLOW | O_NONBLOCK or fail('cannot open approved archive');
    my @st = stat $input;
    @st && S_ISREG($st[2]) or fail('approved archive must be a regular file');
    my $staged = "$transaction/archive";
    sysopen my $file, $staged, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600
        or fail('cannot create protected archive copy');
    binmode $input;
    binmode $file;
    while (1) {
        my $count = sysread($input, my $buffer, 65536);
        defined $count or fail('cannot read approved archive');
        last unless $count;
        print {$file} $buffer or fail('cannot stage approved archive');
    }
    close $file or fail('cannot seal approved archive copy');
    sha256($staged) eq $expected or fail('approved archive SHA-256 does not match');
    mkdir $target, 0700 or fail('cannot create protected extraction directory');
    # The pinned archive is read only after copying it into the protected transaction.
    # bsdtar's default path containment stays enabled and metadata cannot grant access.
    run('/usr/bin/tar', '-xf', $staged, '-C', $target,
        '--no-same-owner', '--no-same-permissions', '--no-acls', '--no-xattrs',
        '--no-fflags', '--no-mac-metadata');
    same_entries($target, $host, $admin);
}

sub absent_or_known {
    my ($path, $label) = @_;
    verify_plist($path, $label) if present($path);
}

sub stage_prior {
    my ($directory, $state) = @_;
    mkdir $directory, 0700 or fail('cannot create protected prior-release backup');
    run('/usr/bin/ditto', "$root/$_", "$directory/$_") for ($host, $admin);
    verify_pair($directory, $state);
    for my $definition ($daemon_plist, $agent_plist) {
        my $backup = "$directory/" . basename($definition);
        my @st = protected($definition, 0);
        copy($definition, $backup) && chown($st[4], $st[5], $backup) && chmod($st[2] & 0777, $backup)
            or fail('cannot back up protected launch definitions');
    }
    verify_plist("$directory/$daemon_label.plist", $daemon_label);
    verify_plist("$directory/$agent_label.plist", $agent_label);
}

sub restore_definition {
    my ($backup, $destination, $label) = @_;
    verify_plist($backup, $label);
    my @st = protected($backup, 0);
    my ($file, $name) = tempfile('.slatehop-restore.XXXXXXXX', DIR => dirname($destination), UNLINK => 0);
    close $file or fail('cannot close staged launch definition');
    my $result = copy($backup, $name) && chown($st[4], $st[5], $name)
        && chmod($st[2] & 0777, $name) && rename($name, $destination);
    unlink $name unless $result;
    $result or fail('cannot restore launch definition atomically');
}

sub apply_release {
    my ($uid, $from, $identity, $original_jobs) = @_;
    no_other_jobs($uid, 1);
    my $writing = "$transaction/writing-definitions";
    if (defined $original_jobs && present($writing)) {
        protected($writing, 0);
        # These named paths were absent when our verified service began generating them.
        # Reject any different loaded program before treating its unregistered output as ours.
        job_info(@{$_}[0..3]) for managed_jobs($uid);
        protected($_, 0) for grep { present($_) } ($daemon_plist, $agent_plist);
    } else {
        absent_or_known($daemon_plist, $daemon_label);
        absent_or_known($agent_plist, $agent_label);
    }

    # Prepare the next complete pair while the old bundle is still accessible.
    my $incoming = tempdir('incoming.XXXXXXXX', DIR => $transaction, CLEANUP => 0);
    if ($identity) {
        run('/usr/bin/ditto', "$from/$_", "$incoming/$_") for ($host, $admin);
        verify_pair($incoming, $identity);
        write_record("$incoming/$receipt", $identity);
    }

    stop_jobs($uid);
    for my $path ($daemon_plist, $agent_plist) {
        unlink $path or fail("cannot remove managed definition: $path") if present($path);
    }
    my $outgoing = tempdir('outgoing.XXXXXXXX', DIR => $transaction, CLEANUP => 0);
    for my $item ($host, $admin, $receipt) {
        next unless present("$root/$item");
        protected("$root/$item", $item ne $receipt);
        rename("$root/$item", "$outgoing/$item") or fail("cannot set aside managed item: $item");
    }
    return unless $identity;

    for my $app ($host, $admin) {
        rename("$incoming/$app", "$root/$app") or fail("cannot place managed App: $app");
    }
    verify_pair($root, $identity);
    if (defined $original_jobs) {
        restore_definition("$from/$daemon_label.plist", $daemon_plist, $daemon_label);
        restore_definition("$from/$agent_label.plist", $agent_plist, $agent_label);
    } else {
        # The managed service writes both existing labels from its final protected path.
        write_record($writing, { uid => $uid });
        run('/bin/sync');
        run("$root/$host/$service", '--write-plists');
    }
    verify_plist($daemon_plist, $daemon_label);
    verify_plist($agent_plist, $agent_label);
    unlink $writing or fail('cannot clear launch definition generation marker') if present($writing);
    host_domains($uid);
    my @jobs = managed_jobs($uid);
    for my $i (0..$#jobs) {
        my $job = $jobs[$i];
        next if defined $original_jobs && !$original_jobs->[$i];
        run($launchctl, 'bootstrap', $job->[0], $job->[2]);
        defined job_info(@{$job}[0..3]) or fail("restored job is not registered: $job->[1]");
    }
    wait_ready($identity) if !defined $original_jobs || $original_jobs->[2];
    rename("$incoming/$receipt", "$root/$receipt") or fail('cannot publish verified live release');
}

sub remove_private_directory {
    my ($path) = @_;
    my @st = protected($path, 1);
    ($st[2] & 0777) == 0700 or fail("transaction staging is not private: $path");
    remove_tree($path, { safe => 1, error => \my $errors });
    @$errors and fail("could not clean protected staging: $path");
}

sub finish_transaction {
    # The rename releases the fail-closed marker in one step; cleanup stays outside commit.
    run('/bin/sync');
    rename $transaction, $complete or fail('cannot atomically close the transaction');
    eval { remove_private_directory($complete); 1 }
        or warn "SlateHop managed host: finished transaction retained at $complete\n";
}

sub verify_recoverable_live_items {
    my (@identities) = grep { defined $_ } @_;
    my $live_host = "$root/$host";
    my $live_admin = "$root/$admin";
    if (present($live_host)) {
        bundle_tree($live_host);
        my $binary = sha256("$live_host/$host_exe");
        my $daemon = sha256("$live_host/$service");
        my ($known) = grep { $_->{host_sha256} eq $binary && $_->{service_sha256} eq $daemon } @identities;
        $known or fail('live host is outside this transaction');
        verify_code($live_host, $known->{team}, $host_id);
    }
    if (present($live_admin)) {
        bundle_tree($live_admin);
        my $binary = sha256("$live_admin/$admin_exe");
        my $pin = plist("$live_admin/Contents/Info.plist")->{SlateHopTrustedHostSHA256} // '';
        my ($known) = grep { $_->{admin_sha256} eq $binary && $_->{host_sha256} eq $pin } @identities;
        $known or fail('live administration app is outside this transaction');
        verify_code($live_admin, $known->{team}, $admin_id);
    }
    if (present("$root/$receipt")) {
        my $live = $json->encode(release_record(read_record("$root/$receipt")));
        grep { $json->encode($_) eq $live } @identities or fail('live release record is outside this transaction');
    }
}

sub recover_transaction {
    protected($transaction, 1);
    if (!present("$transaction/journal.json")) {
        finish_transaction();
        return;
    }
    my $journal = read_record("$transaction/journal.json");
    my $target = release_record($journal->{target});
    my $prior = $journal->{prior};
    my $original_jobs = $journal->{original_jobs};
    ref($original_jobs) eq 'ARRAY' && @$original_jobs == 3
        && !grep { !defined $_ || !/\A[01]\z/ } @$original_jobs
        or fail('malformed journal service state');
    my $state = join '', @$original_jobs;
    $state eq '000' || ($state eq '111' && defined $prior)
        or fail('journal service state cannot be restored exactly');
    if (defined $prior) {
        release_record($prior);
        $prior->{uid} == $target->{uid} && $prior->{port} == $target->{port}
            && $prior->{team} eq $target->{team} or fail('journal identity mismatch');
        verify_pair("$transaction/prior", $prior);
        verify_plist("$transaction/prior/$daemon_label.plist", $daemon_label);
        verify_plist("$transaction/prior/$agent_label.plist", $agent_label);
    }
    verify_recoverable_live_items($prior, $target);
    apply_release($target->{uid}, "$transaction/prior", $prior, $original_jobs);
    finish_transaction();
}

sub usage {
    print STDERR <<'USAGE';
Usage:
  managed-host-install.sh install APPROVED_ARCHIVE SHA256 TEAM_ID SERVING_UID DIRECT_PORT
  managed-host-install.sh update APPROVED_ARCHIVE SHA256 TEAM_ID
  managed-host-install.sh rollback PRIOR_APPROVED_ARCHIVE SHA256 TEAM_ID
  managed-host-install.sh recover
USAGE
    exit 64;
}

sub main {
    my $action = shift @ARGV // '';
    usage() unless ($action eq 'install' && @ARGV == 5)
        || (($action eq 'update' || $action eq 'rollback') && @ARGV == 3)
        || ($action eq 'recover' && !@ARGV);
    $^O eq 'darwin' && $< == 0 && $> == 0 or fail('requires root on macOS');
    chdir '/' or fail('cannot enter trusted working directory');
    umask 022;
    my ($archive, $hash, $team, $serving_uid, $port) = @ARGV;
    if ($action ne 'recover') {
        $archive =~ m{\A/} && $archive !~ /[\x00-\x1f\x7f]/
            && $hash =~ /\A[0-9a-f]{64}\z/ && $team =~ /\A[A-Z0-9]{10}\z/ or usage();
        if ($action eq 'install') {
            $serving_uid =~ /\A[1-9][0-9]{0,9}\z/ && $serving_uid < 4294967295
                && $port =~ /\A[1-9][0-9]{0,4}\z/ && $port <= 65535 or usage();
        }
    }
    protected($_, 1) for ('/', '/Library', '/Library/LaunchDaemons', '/Library/LaunchAgents',
        '/private', '/private/var', '/private/var/log');
    realpath('/var/log') eq '/private/var/log' or fail('unexpected daemon log directory');
    for my $log (qw(rustdesk_service.err rustdesk_service.out)) {
        protected("/private/var/log/$log", 0) if present("/private/var/log/$log");
    }
    if (!present($root)) {
        $action eq 'install' or fail('no managed host exists');
        no_other_jobs($serving_uid, 0);
        !present($daemon_plist) && !present($agent_plist) or fail('existing launch definitions need separate migration');
        mkdir $root, 0755 or present($root) or fail('cannot create protected managed root');
    }
    my ($root_device) = protected($root, 1);
    my ($library_device) = protected('/Library', 1);
    $root_device == $library_device && output('/bin/df', '-Pl', $root) =~ /\n[^\r\n]+\n/
        or fail('the managed host root must be on the local Library volume');
    sysopen my $lock, "$root/.lifecycle.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0600
        or fail('cannot open lifecycle lock');
    my @lock_path = protected("$root/.lifecycle.lock", 0);
    my @lock_fd = stat $lock;
    @lock_fd && $lock_fd[0] == $lock_path[0] && $lock_fd[1] == $lock_path[1] && ($lock_fd[2] & 0777) == 0600
        or fail('unexpected lifecycle lock inode');
    flock $lock, LOCK_EX | LOCK_NB or fail('another managed host operation is in progress');

    if (present($complete)) {
        remove_private_directory($complete);
    }
    if (present($transaction)) {
        $action eq 'recover' or fail('an interrupted transaction requires recover');
        recover_transaction();
        print "Recovered the prior managed state.\n";
        return;
    }
    $action eq 'recover' and fail('no interrupted transaction');

    my $prior;
    my @original_jobs = (0, 0, 0);
    if ($action eq 'install') {
        same_entries($root, '.lifecycle.lock');
        no_other_jobs($serving_uid, 0);
        !present($daemon_plist) && !present($agent_plist) or fail('existing launch definitions need separate migration');
    } else {
        same_entries($root, '.lifecycle.lock', $host, $admin, $receipt);
        $prior = release_record(read_record("$root/$receipt"));
        $prior->{team} eq $team or fail('signing team differs from the managed release');
        ($serving_uid, $port) = @{$prior}{qw(uid port)};
        no_other_jobs($serving_uid, 1);
        verify_pair($root, $prior);
        verify_plist($daemon_plist, $daemon_label);
        verify_plist($agent_plist, $agent_label);
        @original_jobs = prior_job_state($action, $prior);
    }

    mkdir $transaction, 0700 or fail('cannot create protected transaction');
    local $SIG{$_} = sub { fail('interrupted during transaction'); } for qw(HUP INT TERM);
    my $done = eval {
        stage_archive($archive, $hash, "$transaction/target");
        my $target = release_record({
            team => $team, uid => 0 + $serving_uid, port => 0 + $port, archive_sha256 => $hash,
            pair_identity("$transaction/target", $team),
        });
        stage_prior("$transaction/prior", $prior) if $prior;
        write_record("$transaction/pending.json", { prior => $prior, target => $target, original_jobs => \@original_jobs });
        run('/bin/sync');
        rename "$transaction/pending.json", "$transaction/journal.json" or fail('cannot seal rollback journal');
        run('/bin/sync');
        apply_release($serving_uid, "$transaction/target", $target, undef);
        finish_transaction();
        1;
    };
    if (!$done) {
        my $initial = $@;
        eval { recover_transaction(); 1 }
            or fail("transaction failed; protected recovery data retained at $transaction\n$initial$@");
        fail("transaction failed; prior managed state restored\n$initial");
    }
    print "Managed host, launchd jobs and matching administration app are ready.\n";
}

main();
PERL
