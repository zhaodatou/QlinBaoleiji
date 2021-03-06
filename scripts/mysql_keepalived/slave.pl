#!/usr/bin/perl
use warnings;
use strict;
use DBI;
use DBD::mysql;
use File::Basename;
use File::Copy;

our($peer_ip,$local_ip,$interface,$virtual_ip) = @ARGV;
our $user_home_dir = "/root";

unless(defined $peer_ip && defined $local_ip)
{
    print "parameter error\n";
    exit 1;
}

&generate_known_host($peer_ip, 2288);
print "change sql config\n";
&sql_process();

if(defined $interface) 
{
    print "change keepalived config\n";
    unless(-e "/etc/keepalived/keepalived.conf")
    {
        print "/etc/keepalived/keepalived.conf 不存在\n";
        exit 1;
    }

    copy("/etc/keepalived/keepalived.conf","/tmp/keepalived.conf.bak");
    &keepalived_process("/tmp/keepalived.conf.bak");
    copy("/tmp/keepalived.conf.bak","/etc/keepalived/keepalived.conf");
    unlink "/tmp/keepalived.conf.bak";
    &change_rclocal();
    system("killall -9 keepalived");
    system("/usr/local/sbin/keepalived");
}

print "change file config\n";
&file_modify_process("/opt/freesvr/audit/sshgw-audit/etc/freesvr-ssh-proxy_config","AuditAddress",$local_ip);
&file_substitute_process("/opt/freesvr/audit/sshgw-audit/etc/freesvr-ssh-proxy_config","MysqlAddress", "MysqlAddress dbaudithost");

&file_modify_process("/opt/freesvr/audit/etc/global.cfg","global-server",$local_ip);
&file_substitute_process("/opt/freesvr/audit/etc/global.cfg", "mysql-server", "mysql-server=dbaudithost");

&file_modify_process("/etc/xrdp/global.cfg","global-server",$local_ip);
&file_substitute_process("/etc/xrdp/global.cfg", "mysql-server", "mysql-server=dbaudithost");

&file_substitute_process("/opt/freesvr/web/htdocs/freesvr/audit/include/db_connect.inc.php", '\$dbhost', "\$dbhost = 'dbaudithost';");
&file_substitute_process("/opt/freesvr/web/htdocs/freesvr/audit/include/db_connect.inc.php", '\$log_dbhost', "\$log_dbhost = 'dbaudithost';");

&file_modify_process("/opt/freesvr/audit/ftp-audit/etc/freesvr-ftp-audit.conf","AuditAddress",$local_ip);
&file_substitute_process("/opt/freesvr/audit/ftp-audit/etc/freesvr-ftp-audit.conf","MysqlAddress","MysqlAddress\t\t$peer_ip");

&file_substitute_process("/opt/freesvr/audit/authd/etc/freesvr_authd_config","MysqlAddress","MysqlAddress\t\tdbaudithost");

&file_addline_at_end("/etc/hosts", "$peer_ip\tdbaudithost");

&file_substitute_process("/opt/freesvr/audit/rdp-monitord/etc/rdp-monitord.conf","CompressReplayFile","CompressReplayFile\t\tno");
&file_substitute_process("/opt/freesvr/audit/rdp-monitord/etc/rdp-monitord.conf","MysqlAddress","MysqlAddress\t\tdbaudithost");

&cron_modify_process("/home/wuxiaolong/5_backup/backup_session.pl");

&run_programs();

sub sql_process
{
    my $local_dbh=DBI->connect("DBI:mysql:database=audit_sec;host=localhost;mysql_connect_timeout=5","root","",{RaiseError=>1});
    my $utf8 = $local_dbh->prepare("set names utf8");
    $utf8->execute();
    $utf8->finish();

    my $remote_dbh=DBI->connect("DBI:mysql:database=audit_sec;host=$peer_ip;mysql_connect_timeout=5","freesvr","freesvr",{RaiseError=>1});
    $utf8 = $remote_dbh->prepare("set names utf8");
    $utf8->execute();
    $utf8->finish();

    my $sqr_exec = $remote_dbh->prepare("show master status");
    $sqr_exec->execute();
    my $ref_exec = $sqr_exec->fetchrow_hashref();
    my $remote_file = $ref_exec->{"File"};
    my $remote_position = $ref_exec->{"Position"};
    $sqr_exec->finish();

    $sqr_exec = $local_dbh->prepare("stop slave");
    $sqr_exec->execute();
    $sqr_exec->finish();

    $sqr_exec = $local_dbh->prepare("reset slave");
    $sqr_exec->execute();
    $sqr_exec->finish();

    $sqr_exec = $local_dbh->prepare("change master to master_host='$peer_ip',master_user='freesvr',master_password='freesvr',master_log_file='$remote_file',master_log_pos= $remote_position");
    $sqr_exec->execute();
    $sqr_exec->finish();

    $sqr_exec = $local_dbh->prepare("start slave");
    $sqr_exec->execute();
    $sqr_exec->finish();

    my $sqr_select = $local_dbh->prepare("select count(*) from backup_setting where ip = '$peer_ip' and dbname = 'audit_sec' and mysqluser = 'freesvr' and udf_decrypt(mysqlpasswd) = 'freesvr' and session_flag = 1");
    $sqr_select->execute();
    my $ref_select = $sqr_select->fetchrow_hashref();
    if($ref_select->{"count(*)"} == 0)
    {
        my $sqr_insert = $local_dbh->prepare("insert into backup_setting(ip,dbname,mysqluser,mysqlpasswd,session_flag) values('$peer_ip','audit_sec','freesvr',udf_encrypt('freesvr'),1)");
        $sqr_insert->execute();
        $sqr_insert->finish();
    }
    $sqr_select->finish();

    $remote_dbh->disconnect();
    $local_dbh->disconnect();
}

sub keepalived_process
{
	my($file) = @_;

	my @file_context;
	my $flag = 0;

	open(my $fd_fr,"<$file");
	foreach my $line(<$fd_fr>)
	{
		chomp $line;
        if($line =~ /^\s*lvs_sync_daemon_interface/i)
        {
            next;
        }

        if($line =~ /^\s*state/i)
        {
            $line = "state BACKUP";
        }

        if($line =~ /^\s*interface/)
        {
            $line = "\tinterface $interface";
        }

        if($line =~ /^\s*priority/i)
        {
            $line =~ s/\d+/10/;
        }

        if($line =~ /virtual_ipaddress/i)
        {
            $flag = 1;
        }

		if($flag == 1 && $line =~ /(\d{1,3}\.){3}\d{1,3}/)
		{
			$line =~ s/(\d{1,3}\.){3}\d{1,3}/$virtual_ip/;
			$flag = 0;
		}

		push @file_context,$line;
	}
	close $fd_fr;

	open(my $fd_fw,">$file");
	foreach my $line(@file_context)
	{
		print $fd_fw $line,"\n";
	}

	close $fd_fw;
}

sub change_rclocal
{
    my $file = "/etc/rc.local";
    my $dir = dirname $file;
    my $file_name = basename $file;
    my $backup_name = $file_name.".backup";

    unless(-e "$dir/$backup_name")
    {
        copy($file,"$dir/$backup_name");
    }

    my @file_context;
    my $flag = 0;

    open(my $fd_fr,"<$file");
    foreach my $line(<$fd_fr>)
    {
        chomp $line;
        if($line =~ /\/usr\/local\/sbin\/keepalived/i)
        {
            $flag = 1;
        }

        push @file_context,$line;
    }
    close $fd_fr;
    if($flag==0)
    {
        push @file_context,"/usr/local/sbin/keepalived";
    }

    open(my $fd_fw,">$file");
    foreach my $line(@file_context)
    {
        print $fd_fw $line,"\n";
    }

    close $fd_fw;
}

sub file_modify_process
{
    my($file,$attr,$ip) = @_;
    my $dir = dirname $file;
    my $file_name = basename $file;
    my $backup_name = $file_name.".backup";

    unless(-e "$dir/$backup_name")
    {
        copy($file,"$dir/$backup_name");
    }

    open(my $fd_fr,"<$file") or die "cannot open $file";

    my @file_context;
    foreach my $line(<$fd_fr>)
    {
        chomp $line;
        if($line =~ /^$attr/i)
        {
            $line =~ s/(\d{1,3}\.){3}\d{1,3}/$ip/;
        }

        push @file_context,$line;
    }

    close $fd_fr;

    open(my $fd_fw,">$file");
    foreach my $line(@file_context)
    {
        print $fd_fw $line,"\n";
    }

    close $fd_fw;
}

sub file_substitute_process
{
    my($file,$attr,$new_value) = @_;
    my $dir = dirname $file;
    my $file_name = basename $file;
    my $backup_name = $file_name.".backup";

    unless(-e "$dir/$backup_name")
    {
        copy($file,"$dir/$backup_name");
    }

    open(my $fd_fr,"<$file") or die "cannot open $file";

    my @file_context;
    foreach my $line(<$fd_fr>)
    {
        chomp $line;
        if($line =~ /^$attr/i)
        {
            $line = $new_value;
        }

        push @file_context,$line;
    }

    close $fd_fr;

    open(my $fd_fw,">$file");
    foreach my $line(@file_context)
    {
        print $fd_fw $line,"\n";
    }

    close $fd_fw;
}

sub file_addline_at_end
{
    my($file,$new_line) = @_;
    my $new_line_with_one_space = join " ", (split /\s+/, $new_line);

    my $dir = dirname $file;
    my $file_name = basename $file;
    my $backup_name = $file_name.".backup";
    my $found = 0;

    unless(-e "$dir/$backup_name")
    {   
        copy($file,"$dir/$backup_name");
    }

    open(my $fd_fr,"<$file") or die "cannot open $file";

    my @file_context;
    foreach my $line(<$fd_fr>)
    {   
        chomp $line;
        push @file_context,$line;

        my $line_with_one_space = join " ", (split /\s+/, $line);
        if($new_line_with_one_space eq $line_with_one_space)
        {   
            $found = 1;
        }
    }

    if($found == 0)
    {   
        push @file_context,$new_line;
    }

    close $fd_fr;

    open(my $fd_fw,">$file");
    foreach my $line(@file_context)
    {   
        print $fd_fw $line,"\n";
    }

    close $fd_fw;
}

sub cron_modify_process
{
    my($file) = @_;

    if(-e "/var/spool/cron/root")
    {
        open(my $fd_fr,"</var/spool/cron/root");
        my @file_context;
        my $flag = 0;
        foreach my $line(<$fd_fr>)
        {
            chomp $line;
            if($line =~ /$file/i)
            {
                $flag = 1;
                $line = "*/5 * * * * $file";
            }

            push @file_context,$line;
        }

        if($flag == 0)
        {
            push @file_context,"*/5 * * * * $file";
        }

        close $fd_fr;

        open(my $fd_fw,">/var/spool/cron/root");
        foreach my $line(@file_context)
        {
            print $fd_fw $line,"\n";
        }

        close $fd_fw;
    }
    else
    {
        open(my $fd_fw,">/var/spool/cron/root");
        print $fd_fw "*/5 * * * * $file\n";
        close $fd_fw;
    }
}

sub run_programs 
{
    if(system("/opt/freesvr/audit/sbin/manageprocess.pl ftp-audit restart") != 256)
    {
        print "run manageprocess.pl ftp-audit restart error\n";
        exit(1);
    }

    if(system("/opt/freesvr/audit/sbin/manageprocess.pl Freesvr_RDP restart") != 256)
    {
        print "run manageprocess.pl Freesvr_RDP restart error\n";
        exit(1);
    }


    if(system("/opt/freesvr/audit/sbin/manageprocess.pl ssh-audit restart") !=256)
    {
        print "run manageprocess.pl ssh-audit restart error\n";
        exit(1);
    }

    if(system("/opt/freesvr/audit/sbin/manageprocess.pl freesvr-authd restart") != 256)
    {
        print "run manageprocess.pl freesvr-authd restart error\n";
        exit(1);
    }

    if(system("killall -9 rdp-monitord") != 0)
    {
        print "run killall -9 rdp-monitord error\n";
        exit(1);
    }

    if(system("/opt/freesvr/audit/rdp-monitord/sbin/rdp-monitord") != 0)
    {
        print "run rdp-monitord error\n";
        exit(1);
    }
}

sub generate_known_host
{   
    my($host,$port) = @_;
    my $output = `ssh-keyscan -t ecdsa -p $port $host 2>/dev/null`;
    my $type;
    my $pubkey;
    my $cur_line = undef;
    foreach my $line(split /\n/,$output)
    {   
        chomp $line;
        if($line =~ /^$host/)
        {   
            ($type,$pubkey) = (split /\s+/, $line)[1,2];
            $cur_line = $line;
            last;
        }
    }
    unless(defined $cur_line)
    {   
        return;
    }

    my $change = 1;
    my @cache;
    push @cache, $cur_line;
    my $file = "$user_home_dir/.ssh/known_hosts";
    if(-e $file)
    {   
        open(my $fd_fr, "<$file");
        while(my $line = <$fd_fr>)
        {   
            chomp $line;
            if($line =~ /^$host/)
            {   
                my($tmp_type,$tmp_pubkey) = (split /\s+/, $line)[1,2];
                if($tmp_type eq $type && $tmp_pubkey eq $pubkey)
                {   
                    $change = 0;
                }
            }
            else
            {   
                push @cache, $line;
            }
        }
        close $fd_fr;
    }

    if($change==1)
    {   
        open(my $fd_fw, ">$file");
        foreach my $line(@cache)
        {   
            print $fd_fw $line,"\n";
        }
        close $fd_fw;
    }
}
