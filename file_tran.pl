#!/usr/bin/perl


use strict						;
#use warnings				;
#v. 0.11 SFTP: only regular files are transferred (".", "..", directories and other special entries are skipped);
#        the error e-mail names the server the script ran on and the SFTP server.
#v. 0.10 Files are deleted from input only after a successful transfer; every copy/gzip/archive/delete
#        error is logged and e-mailed (Notification:Y).
#v. 0.09 Bugfixes (SFTP error check, date substr/len comparisons, printf format-string),
#        robust stat-based size/date handling, atomic File::Copy::move, LogMode:None support,
#        and mandatory logging of file creation/modification date before every transfer.

use Data::Dumper		;
use DirHandle				;
use File::Basename		;
use File::Copy				;
use File::Find::Rule		;
use Array::Utils qw(:all)	;
use Net::SFTP::Foreign	;
use MIME::Lite				;
use Date::Parse			;
use DateTime				;
use Sys::Hostname		;
use Fcntl ':mode'		;

my $script_version = '0.11';


########## Crontab Row; ##########
##5,10,15 * * * * /path/to/script/file_tran.pl /path/to/ini/file/file.param
# - - - - -
# | | | | |
# | | | | +----- day of week   	(0 - 6) (Sunday=0)
# | | | +------- month 		   	(1 - 12)
# | | +--------- day of month  	(1 - 31)
# | +----------- hour 		   		(0 - 23)
# +------------- min 		   		(0 - 59)

my $param_file = $ARGV[0]		  ; 
my $param_file_type = '\.param$';
my @message							  ;

######### Determin if the input .param file is good for execution; #########

if (!defined $param_file || $param_file eq ''){
	push (@message, "****** No parameter file is provided, can't do jack,exiting...  ******") && push (@message, '<br>')
	&& die "No parameter file is provided, can't do jack!"."\n";}
elsif (!-f $param_file){ 
	push (@message, "****** File ".$param_file." is not loaded, not a file,exiting...  ******") && push (@message, '<br>')
	&& die "File ".$param_file." is not loaded, not a file!"."\n";	
}
elsif ($param_file !~ $param_file_type){
	push (@message, "****** File ".$param_file." is not loaded, does not comply with .param file type,exiting...  ******") && push (@message, '<br>')
	&& die "File ".$param_file." is not loaded, does not comply with .param file type"."\n";
}

######### Check for same instance running; #########
my $res;

$res = `ps -ef |grep -v grep |grep "file_tran.pl $param_file" |grep -v vi |grep -v sh |wc -l`;
chomp( $res );

if( $res >= 2 ){
   die "We found an instance of the same script!"."\n";
}
else{
	#print "No instances of the script found."."\n";
}


######### Load input parameters from selected file; #########

open(FILE,"<$param_file") or die "Can't open parameter file $param_file: $!\n";
my %hash;
while (my $line=<FILE>) {

chomp $line;
(my $key,my $value) = split /:/, $line;

$hash{$key} = $value;
}

close FILE;
######### Parametarization check; #########

my $InputDir 				= $hash{'InputDir'}			   ;
my $OutputDir 				= $hash{'OutputDir'}		       ;
my $KeepInput				= $hash{'KeepInput'}		   ;
my $SftpCheck 			= $hash{'SftpCheck'}		   ;
my $SftpType 				= $hash{'SftpType'}			   ;
my $SftpPassFile 			= $hash{'SftpPassFile'}		   ;
my $SftpHost 				= $hash{'SftpHost'}			   ;
my $SftpUser 				= $hash{'SftpUser'}			   ;
my $SftpKey 				= $hash{'SftpKey'}			   ;
my $FileMask 				= $hash{'FileMask'}			   ;
my $SubDirCheck 		= $hash{'SubDirCheck'}	   ;
my $SizeCheck 			= $hash{'SizeCheck'}		   ;
my $CtlFileCheck 			= $hash{'CtlFileCheck'}		   ;
my $CtlFileExtension 		= $hash{'CtlFileExtension'}	   ;
my $GzipOutput 			= $hash{'GzipOutput'}		   ;
my $GzipInput 				= $hash{'GzipInput'}		 	   ;
my $ArchiveCheck 		= $hash{'ArchiveCheck'}	   ;
my $ArchiveDir 			= $hash{'ArchiveDir'}		   ;
my $LogMode 				= $hash{'LogMode'}			   ;
my $LogDir					= $hash{'LogDir'}			 	   ;
my $LogFile					= $hash{'LogFile'}			 	   ;
my $Notification 			= $hash{'Notification'}		   ;
my $NotificationSender 	= $hash{'NotificationSender'};
my $NotificationRe 		= $hash{'NotificationRe'}	   ;
my $NotificationCc 		= $hash{'NotificationCc'}	   ;
my $NotificationMethod  = $hash{'NotificationMethod'} ;
my $NotificationServer   = $hash{'NotificationServer'} ;
my $FileDateCheck 		= $hash{'FileDateCheck'}	   ;
my $FileCreationDate 	= $hash{'FileCreationDate'}   ;


######### Try 1 for simple perl as input para #######

my $eval_is = eval ($FileMask);
if (!$@ && defined $eval_is){

	# FileMask was a valid Perl snippet that returned a RegEx string; use its result.
	$FileMask = $eval_is;

}
# else: FileMask is a plain RegEx string - keep it as-is (evaluated only once above).

######### Testing Ground; #########

my $lf = LoggerNew(); #main::LoggerNew() called too early to check prototype at ./file_tran.pl line 84.

InitLog()			;			  #main::InitLog() called too early to check prototype at ./file_tran.pl line 85.

END {
	if($Notification eq 'Y'){

		Notification($NotificationSender,$NotificationRe,$NotificationCc,@message);

	}
}
######### DateTime Ground; #########
my $between_dates_check		;
my $first_between_date			;
my $second_between_date	;
my $expected_format_1		;
my $expected_format_2		;

if ( $FileDateCheck eq 'Y'){
	$lf->LoggerStringToFile( "****** FileDateCheck Enabled parsing dates: $FileDateCheck  ******" );
	$between_dates_check = 1;

	if ($FileCreationDate =~ /&date/){
		$lf->LoggerStringToFile( "****** Multiple Dates extracted checking dates...  ******" );
		my @between_dates = split /&date/, $FileCreationDate;
		
		if (scalar(@between_dates) != 2){
			$lf->LoggerStringToFile( "****** Dates provided in array are different than TWO (2) dates: ".scalar(@between_dates)."  Working with those dates aborted script will continue without usage of dates for comparison ******" );
			$between_dates_check = 0;
			}
		elsif (scalar(@between_dates) == 2){
			$lf->LoggerStringToFile( "****** Provided TWO(2) dates : ".scalar(@between_dates)."  Entering Date validation ******" );
			$between_dates_check = 1;
			
			$between_dates[0] =~ s/^\s+|\s+$//g;			
			
			if ( $between_dates[0] =~ /^\d/){
				$between_dates[0] = $between_dates[0];

			}
			else{
				
				my $eval_date_is_1 = eval ($between_dates[0]);
				if ($@){
				
					$between_dates[0] = $between_dates[0];
				
				}
				else{
				
					$between_dates[0] = eval($between_dates[0]);
				
				}
			}
			
			$between_dates[1] =~ s/^\s+|\s+$//g;			
			
			if ( $between_dates[1] =~ /^\d/){
				$between_dates[1] = $between_dates[1];

			}
			else{
				
				my $eval_date_is_2 = eval ($between_dates[1]);
				if ($@){
				
					$between_dates[1] = $between_dates[1];
				
				}
				else{
				
					$between_dates[1] = eval($between_dates[1]);
				
				}
			}

			
			my $first_date_in = $between_dates[0];
			$first_date_in =~ s/^\s+|\s+$//g; #triming leading/trailing whitespaces
			
			my $len_first_date_in = length( $first_date_in );
			
			if ( $len_first_date_in == 10 || $len_first_date_in == 13 || $len_first_date_in == 16 || $len_first_date_in == 19){
				$lf->LoggerStringToFile( "****** First Date string acceptable by lenght : 10/13/16/19 actual : $len_first_date_in ******" );
				$lf->LoggerStringToFile( "****** No additional formating will be done ******" );
			
				if ( $len_first_date_in == 10 ){
				
					$lf->LoggerStringToFile( "****** First Date string accepted lenght : 10 actual : $len_first_date_in. Will run with expected format : day******" );
					$expected_format_1 = 'day';
				
				}
				elsif ( $len_first_date_in == 13){
				
					$lf->LoggerStringToFile( "****** First Date string accepted lenght : 13 actual : $len_first_date_in. Will run with expected format : hour******" );
					$expected_format_1 = 'hour';
				
				}
				elsif ( $len_first_date_in == 16){
				
					$lf->LoggerStringToFile( "****** First Date string accepted lenght : 16 actual : $len_first_date_in. Will run with expected format : min******" );
					$expected_format_1 = 'minute';
				
				}
				elsif ( $len_first_date_in == 19){
				
					$lf->LoggerStringToFile( "****** First Date string accepted lenght : 19 actual : $len_first_date_in. Will run with expected format : full timestamp compare******" );
					$expected_format_1 = 'second';
				
				}
			}
			elsif ( $len_first_date_in > 19){
			
				$lf->LoggerStringToFile( "****** First Date string above maximum accepted lenght : 19 actual : $len_first_date_in. Attempting trim******" );
				$first_date_in = substr($first_date_in,0,19);
				$expected_format_1 = 'second';
			
			}
			elsif ( $len_first_date_in < 10){
			
				$lf->LoggerStringToFile( "****** First Date string accepted lenght but with warning : under 10 actual : $len_first_date_in. Will attempt padding******" );
			
				if ( $len_first_date_in > 7 && $len_first_date_in < 10){
				
					$lf->LoggerStringToFile( "****** First Date string accepted lenght but with warning : between 7 && 10 actual : $len_first_date_in. Will run with expected format : mon******" );
					$expected_format_1 = 'month';
					$first_date_in = substr($first_date_in,0,7).'-01';
				
				}
				elsif ( $len_first_date_in > 4 && $len_first_date_in < 7 ){
				
					$lf->LoggerStringToFile( "****** First Date string accepted lenght but with warning : between 4 && 7 actual : $len_first_date_in. Will run with expected format : year******" );
					$expected_format_1 = 'year';
					$first_date_in = substr($first_date_in,0,4).'-01-01';
				
				}
				elsif ( $len_first_date_in == 4){
				
					$lf->LoggerStringToFile( "****** First Date string accepted lenght but with warning : between 4 && 7 actual : $len_first_date_in. Will run with expected format : year******" );
					$expected_format_1 = 'year';
					$first_date_in = substr($first_date_in,0,4).'-01-01';				
				
				}
				elsif ( $len_first_date_in < 4){
				
					$lf->LoggerStringToFile( "****** First Date string accepted lenght but with warning : under 4 actual : $len_first_date_in. Will run with expected format : year and will get current year******" );
					$expected_format_1 = 'year';
					my ($sec,$min,$hour,$mday,$mon,$year) = localtime();
					$year = sprintf("%02d", $year+1900);
					$first_date_in = $year;
					$first_date_in = $first_date_in.'-01-01';
				
				}
			}
			
			
			my $second_date_in = $between_dates[1];
			$second_date_in =~ s/^\s+|\s+$//g; #triming leading/trailing whitespaces
			
			#print $second_date_in."\n";
			
			my $len_second_date_in = length( $second_date_in );
			
			if ( $len_second_date_in == 10 || $len_second_date_in == 13 || $len_second_date_in == 16 || $len_second_date_in == 19){
				$lf->LoggerStringToFile( "****** Second Date string acceptable by lenght : 10/13/16/19 actual : $len_second_date_in ******" );
				$lf->LoggerStringToFile( "****** No additional formating will be done ******" );
			
				if ( $len_second_date_in == 10 ){
				
					$lf->LoggerStringToFile( "****** Second Date string accepted lenght : 10 actual : $len_second_date_in. Will run with expected format : day******" );
					$expected_format_2 = 'day';
				
				}
				elsif ( $len_second_date_in == 13){
				
					$lf->LoggerStringToFile( "****** Second Date string accepted lenght : 13 actual : $len_second_date_in. Will run with expected format : hour******" );
					$expected_format_2 = 'hour';
				
				}
				elsif ( $len_second_date_in == 16){
				
					$lf->LoggerStringToFile( "****** Second Date string accepted lenght : 16 actual : $len_second_date_in. Will run with expected format : min******" );
					$expected_format_2 = 'minute';
				
				}
				elsif ( $len_second_date_in == 19){
				
					$lf->LoggerStringToFile( "****** Second Date string accepted lenght : 19 actual : $len_second_date_in. Will run with expected format : full timestamp compare******" );
					$expected_format_2 = 'second';
				
				}
			}
			elsif ( $len_second_date_in > 19){
			
				$lf->LoggerStringToFile( "****** Second Date string above maximum accepted lenght : 19 actual : $len_second_date_in. Attempting trim******" );
				$second_date_in = substr($second_date_in,0,19);
				$expected_format_2 = 'second';
			
			}
			elsif ( $len_second_date_in < 10){
			
				$lf->LoggerStringToFile( "****** Second Date string accepted lenght but with warning : under 10 actual : $len_second_date_in. Will attempt padding******" );
			
				if ( $len_second_date_in > 7 && $len_second_date_in < 10){
				
					$lf->LoggerStringToFile( "****** Second Date string accepted lenght but with warning : between 7 && 10 actual : $len_second_date_in. Will run with expected format : mon******" );
					$expected_format_2 = 'month';
					$second_date_in = substr($second_date_in,0,7).'-01';
				
				}
				elsif ( $len_second_date_in > 4 && $len_second_date_in < 7 ){
				
					$lf->LoggerStringToFile( "****** Second Date string accepted lenght but with warning : between 4 && 7 actual : $len_second_date_in. Will run with expected format : year******" );
					$expected_format_2 = 'year';
					$second_date_in = substr($second_date_in,0,4).'-01-01';
				
				}
				elsif ( $len_second_date_in == 4){
				
					$lf->LoggerStringToFile( "****** Second Date string accepted lenght but with warning : between 4 && 7 actual : $len_second_date_in. Will run with expected format : year******" );
					$expected_format_2 = 'year';
					$second_date_in = substr($second_date_in,0,4).'-01-01';				
				
				}
				elsif ( $len_second_date_in < 4){
				
					$lf->LoggerStringToFile( "****** Second Date string accepted lenght but with warning : under 4 actual : $len_second_date_in. Will run with expected format : year and will get current year******" );
					$expected_format_2 = 'year';
					my ($sec,$min,$hour,$mday,$mon,$year) = localtime();
					$year = sprintf("%02d", $year+1900);
					$second_date_in = $year;
					$second_date_in = $second_date_in.'-01-01';
				
				}
			}
		
			my $epoch_first_date 	 = str2time($first_date_in)		;
			my $epoch_second_date = str2time($second_date_in)	;
			
			
			
			$first_between_date = DateTime->from_epoch( epoch => $epoch_first_date );
			$first_between_date -> set_time_zone( 'local' );
			$first_between_date-> truncate ( to => "$expected_format_1");
			$second_between_date = DateTime->from_epoch(epoch => $epoch_second_date);
			$second_between_date -> set_time_zone( 'local' );
			$second_between_date-> truncate ( to => "$expected_format_2");
		
		}
	}
	else{
		$lf->LoggerStringToFile( "****** Single Date extracted starting checks...  ******" );
		$between_dates_check = 2;
		
		my $first_date_in = $FileCreationDate;
		$first_date_in =~ s/^\s+|\s+$//g; #triming leading/trailing whitespaces
		
		if ( $first_date_in =~ /^\d/){
				$first_date_in = $first_date_in;

		}
		else{
				
			my $eval_date_is_1 = eval ($first_date_in);
			if ($@){
				
				$first_date_in = $first_date_in;
				#print "We didn't do the eval"."\n";
				
			}
			else{
				
				$first_date_in = eval($first_date_in);
				#print "We did the eval"."\n";
				
			}
		}
		
		#print $first_date_in."\n";
		
		my $len_first_date_in = length( $first_date_in );
			
			if ( $len_first_date_in == 10 || $len_first_date_in == 13 || $len_first_date_in == 16 || $len_first_date_in == 19){
				$lf->LoggerStringToFile( "****** First Date string acceptable by lenght : 10/13/16/19 actual : $len_first_date_in ******" );
				$lf->LoggerStringToFile( "****** No additional formating will be done ******" );
			
				if ( $len_first_date_in == 10 ){
				
					$lf->LoggerStringToFile( "****** First Date string accepted lenght : 10 actual : $len_first_date_in. Will run with expected format : day******" );
					$expected_format_1 = 'day';
				
				}
				elsif ( $len_first_date_in == 13){
				
					$lf->LoggerStringToFile( "****** First Date string accepted lenght : 13 actual : $len_first_date_in. Will run with expected format : hour******" );
					$expected_format_1 = 'hour';
				
				}
				elsif ( $len_first_date_in == 16){
				
					$lf->LoggerStringToFile( "****** First Date string accepted lenght : 16 actual : $len_first_date_in. Will run with expected format : min******" );
					$expected_format_1 = 'minute';
				
				}
				elsif ( $len_first_date_in == 19){
				
					$lf->LoggerStringToFile( "****** First Date string accepted lenght : 19 actual : $len_first_date_in. Will run with expected format : full timestamp compare******" );
					$expected_format_1 = 'second';
				
				}
			}
			elsif ( $len_first_date_in > 19){
			
				$lf->LoggerStringToFile( "****** First Date string above maximum accepted lenght : 19 actual : $len_first_date_in. Attempting trim******" );
				$first_date_in = substr($first_date_in,0,19);
				$expected_format_1 = 'second';
			
			}
			elsif ( $len_first_date_in < 10){
			
				$lf->LoggerStringToFile( "****** First Date string accepted lenght but with warning : under 10 actual : $len_first_date_in. Will attempt padding******" );
			
				if ( $len_first_date_in > 7 && $len_first_date_in < 10){
				
					$lf->LoggerStringToFile( "****** First Date string accepted lenght but with warning : between 7 && 10 actual : $len_first_date_in. Will run with expected format : mon******" );
					$expected_format_1 = 'month';
					$first_date_in = substr($first_date_in,0,7).'-01';
				
				}
				elsif ( $len_first_date_in > 4 && $len_first_date_in < 7 ){
				
					$lf->LoggerStringToFile( "****** First Date string accepted lenght but with warning : between 4 && 7 actual : $len_first_date_in. Will run with expected format : year******" );
					$expected_format_1 = 'year';
					$first_date_in = substr($first_date_in,0,4).'-01-01';
				
				}
				elsif ( $len_first_date_in == 4){
				
					$lf->LoggerStringToFile( "****** First Date string accepted lenght but with warning : between 4 && 7 actual : $len_first_date_in. Will run with expected format : year******" );
					$expected_format_1 = 'year';
					$first_date_in = substr($first_date_in,0,4).'-01-01';				
				
				}
				elsif ( $len_first_date_in < 4){
				
					$lf->LoggerStringToFile( "****** First Date string accepted lenght but with warning : under 4 actual : $len_first_date_in. Will run with expected format : year and will get current year******" );
					$expected_format_1 = 'year';
					my ($sec,$min,$hour,$mday,$mon,$year) = localtime();
					$year = sprintf("%02d", $year+1900);
					$first_date_in = $year;
					$first_date_in = $first_date_in.'-01-01';
				
				}
			}
			
		#print $first_date_in."\n";
		
		my $epoch_first_date 	 = str2time($first_date_in)		;
		$first_between_date = DateTime->from_epoch( epoch => $epoch_first_date );
		$first_between_date -> set_time_zone( 'local' );
		$first_between_date-> truncate ( to => "$expected_format_1");
	
	}
}

if ( $SftpCheck eq 'N' ){
	$lf->LoggerStringToFile( "****** STFP Disabled entering local transfer  ******" );

	my @local_dirs;
	if ( $SubDirCheck eq 'Y' ){
		@local_dirs = File::Find::Rule->new
		->directory
		->in($InputDir);
		
		foreach my $InputDirArr (@local_dirs){
		
			if (-d $InputDirArr){
			
				GetFilesLocal($InputDirArr."/",$OutputDir,$FileMask);
			
			}			
		}	
	}
	elsif ( $SubDirCheck eq 'N' ){
	
		GetFilesLocal($InputDir,$OutputDir,$FileMask);
	
	}
}
elsif($SftpCheck eq 'Y'){

	###Sftp host###
	my $sftp;
	
	if ( $SftpType eq 'Clear' ){
	
		$lf->LoggerStringToFile("****** STFP Clear connection accessing pass file  ******");
		if (-f $SftpPassFile){
		
			$lf->LoggerStringToFile("****** STFP Pass file provided attempting read  ******");
			############################################# Read password from file Crypt password file or do somethign so no1 can see it.
			my $password;
			open(PW_FILE,"<$SftpPassFile") or $lf->LoggerStringToFile("****** STFP Pass cannot be open,exiting...  ******") 
			&& push (@message, '****** STFP Pass cannot be open,exiting...  ******') && push (@message, '<br>')
			&& die "****** STFP Pass cannot be open,exiting...  ******";
			while (my $line=<PW_FILE>) {

				chomp $line;
				if (!defined $password || $password eq ''){
			
					$password = $line;
			
				}
				elsif ($password){
			
					$lf->LoggerStringToFile("****** First line was provided as password, multiple lines in the .pass file. Please check.  ******");
				}
			}
			close PW_FILE;
			
			$sftp = Net::SFTP::Foreign->
             new(host => $SftpHost,
				user => $SftpUser,
				password => $password, #Here should be the password;
                  #key_path => $privateKey,
		 #more => '-v'
			);
		}
		else{
		
			$lf->LoggerStringToFile("****** STFP Pass file NOT provided,exiting... ******"); #or die
			push (@message, "****** STFP Pass file NOT provided,exiting... ******") && push (@message, '<br>')
			&& die "STFP Pass file NOT provided,exiting... "."\n";
		
		}
	
	}
	elsif ( $SftpType eq 'Key' ){
	
		$lf->LoggerStringToFile("****** STFP Key connection accessing key file  ******");	
		if (-f $SftpKey){
		
			$lf->LoggerStringToFile("****** STFP Key file provided ******");
			############################################# Read password from file Crypt password file or do somethign so no1 can see it.
			
		$sftp = Net::SFTP::Foreign->
             new(host => $SftpHost,
				user => $SftpUser,
				#password => ,
                  key_path => $SftpKey,
		 #more => '-v'
        );
		}
		else{
		
			$lf->LoggerStringToFile("****** STFP Key file NOT provided,exiting... ******");
			push (@message, "****** STFP Key file NOT provided,exiting... ******") && push (@message, '<br>')
			&& die "STFP Key file NOT provided,exiting..."."\n";			#or die
		
		}
	
	}
	else {
	
		$lf->LoggerStringToFile("****** Can't decide wich sftp method to use please check,exiting...  ******");	#or die
		push (@message, "****** Can't decide wich sftp method to use please check,exiting... ******") && push (@message, '<br>')
		&& die "Can't decide wich sftp method to use please check,exiting..."."\n";
	}
	
	if (!$sftp->error){
		$lf->LoggerStringToFile("****** STFP Connection established ******");
	}
	else {
		$lf->LoggerStringToFile("****** Error in STFP connection ******");
		push (@message, "****** Error in STFP connection,exiting... ******") && push (@message, '<br>')
		&& die "Error in STFP connection,exiting..."."\n";
	}
	
	$lf->LoggerStringToFile( "****** STFP Enabled entering sftp transfer  ******" );

	if ( $SubDirCheck eq 'Y' ){
	
		$lf->LoggerStringToFile( "****** SubDir for SFTP enabled entering subdir check  ******" );
		
		my @sftp_dirs = $sftp->find($InputDir);
		my @sftp_dir_final					  ;
		push (@sftp_dir_final, $InputDir)	  ;
		
		foreach  my $sftp_dir (@sftp_dirs) {
			foreach my $sftp_dir1 ($sftp_dir){
				my @drows = split( " ", $sftp_dir1->{'longname'});
				if ($drows[0] =~ /^d/){
				
					push (@sftp_dir_final, $sftp_dir1->{'filename'}."/")
				
				}			
			}	
		}
	
	
		foreach my $sftp_dir_final(@sftp_dir_final){
		
			GetFilesRemote($sftp,$sftp_dir_final,$OutputDir,$FileMask);	
		
		}		
	}
	elsif ( $SubDirCheck eq 'N' ){
	
		GetFilesRemote($sftp,$InputDir,$OutputDir,$FileMask);	
	
	}	
}
else{

	die "No proper value for SftpCheck: ".$SftpCheck." provided can not determine proper sub!"."\n";

}

######### Logger Subs and build; #########

sub InitLog() {
	$lf->LoggerOpenFile( "$LogDir$LogFile" );
	$lf->LoggerPrintProcNum( 1 );
	$lf->LoggerPrintCurDate( 1 );
	$lf->LoggerPrintCurTime( 1 );
	$lf->LoggerHeader( "[ " );
	$lf->LoggerPrintMsgHeader( 1 );
	$lf->LoggerFooter( " ]\n" );
	$lf->LoggerPrintMsgFooter( 1 );
}

sub LoggerNew() {
	
	my $proto 	= shift;
	my $class 	= ref( $proto ) || $proto;
	my $self 	= {};

	$self->{LOG_FILE_NAME} 		= undef;
	$self->{MSG_HEADER} 		= "";
	$self->{MSG_FOOTER} 		= "";
	$self->{PRINT_PROC_NUM} 	= 0;
	$self->{PRINT_CURR_DATE} 	= 0;
	$self->{PRINT_CURR_TIME} 	= 0;
	$self->{PRINT_MSG_HEADER} 	= 0;
	$self->{PRINT_MSG_FOOTER} 	= 0;

	bless( $self, $class );
	return $self;
	
}

sub LoggerFileName() {

	my $self = shift;

	if (@_) { $self->{LOG_FILE_NAME} = shift }
	return $self->{LOG_FILE_NAME};

}

sub LoggerHeader() {

	my $self = shift;

	if (@_) { $self->{MSG_HEADER} = shift }
	return $self->{MSG_HEADER};

}

sub LoggerFooter() {

	my $self = shift;

	if (@_) { $self->{MSG_FOOTER} = shift }
	return $self->{MSG_FOOTER};

}

sub LoggerPrintProcNum() {

	my $self = shift;

	if (@_) { $self->{PRINT_PROC_NUM} = shift }
	return $self->{PRINT_PROC_NUM};

}

sub LoggerPrintCurDate() {

	my $self = shift;

	if (@_) { $self->{PRINT_CURR_DATE} = shift }
	return $self->{PRINT_CURR_DATE};

}

sub LoggerPrintCurTime() {

	my $self = shift;

	if (@_) { $self->{PRINT_CURR_TIME} = shift }
	return $self->{PRINT_CURR_TIME};

}

sub LoggerPrintMsgHeader() {

	my $self = shift;

	if (@_) { $self->{PRINT_MSG_HEADER} = shift }
	return $self->{PRINT_MSG_HEADER};

}

sub LoggerPrintMsgFooter() {

	my $self = shift;

	if (@_) { $self->{PRINT_MSG_FOOTER} = shift }
	return $self->{PRINT_MSG_FOOTER};

}

sub LoggerOpenFile() {

	my $self = shift;
	my $fileName = shift;

	open( LOG_FILE_HANDLER, ">> $fileName" )
		|| die "Can't open $fileName for appending: $!\n";
	
	select( LOG_FILE_HANDLER );
	$| = 1;
	select( stdout );

}

sub LoggerCloseFile() {

	my $self = shift;

	close( LOG_FILE_HANDLER ) 
		|| die "Can't close " . $self->{LOG_FILE_NAME} . ": $!\n";

}

sub LoggerStringToFile() {

	my $self = shift;
	my $msg = shift;

	# Respect LogMode: 'None' disables file logging completely.
	return if ( defined $LogMode && $LogMode eq 'None' );

	my $str = undef;
	my $sec =undef;
	my $min =undef;
	my $hour =undef;
	my $mday =undef;
	my $mon =undef;
	my $year =undef;
	my $wday =undef;
	my $yday =undef;
	my $isdst =undef;

	($sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst ) =
		localtime( time );
	
	$year -= 100;
	if( $year >= 0 && $year <= 9 ){ $year = "0" . $year; }

  if( $mday >= 1 && $mday <= 9 ){ $mday = "0" . $mday; }

  if( $hour >= 0 && $hour <= 9 ){ $hour = "0" . $hour; }
  if( $min >= 0 && $min <= 9 ){ $min = "0" . $min; }
  if( $sec >= 0 && $sec <= 9 ){ $sec = "0" . $sec; }


	$str = "";

	if( $self->{PRINT_PROC_NUM} ) {
		$str .= "$$: ";
	}

	if( $self->{PRINT_CURR_DATE} ) {
		$mon++;
		if( $mon >= 0 && $mon <= 9 ){ $mon = "0" . $mon; }
		$str .= "$mday/$mon/$year ";
	}

	if( $self->{PRINT_CURR_TIME} ) {
		$str .= "$hour:$min:$sec ";
	}

	if( $self->{PRINT_MSG_HEADER} ) {
		$str .= $self->{MSG_HEADER};
	}

	$str .= $msg;

	if( $self->{PRINT_MSG_FOOTER} ) {
		$str .= $self->{MSG_FOOTER};
	}

	print LOG_FILE_HANDLER $str;

}
######### GetFiles Local Subs and build; #########

sub GetFilesLocal() {

	my $InputDir 			= shift;
	my $OutputDir 			= shift;
	my $FileMask 			= shift;

	$lf->LoggerStringToFile( "****** START Transit files ******" );
	$lf->LoggerStringToFile( "****** Param is as following : InputDir = $InputDir; OutputDir = $OutputDir; Searching FileMask = $FileMask; ******" );


	chdir( $InputDir ) || do { ReportError( "Can't chdir to $InputDir: $!" ); die "Can't chdir to $InputDir\n"; };
	
	my $DataDir = DirHandle->new("$InputDir");
	my $file								 ;
	my $ARR								 ;
	my %ARR								 ;
	my @ARR_files_size				 ;
	my @ARR_ctl_check				 ;
	my @ARR_rdy_files				 ;
	my @res1								 ;
	my $res_size						 ;
	my $ready_files 				     ;
	my @output_dirs					 ;
	my %failed_files; # files that were NOT transferred completely - these must never be deleted from input
	
	if ($OutputDir =~ /,/){ #Hardcoded Delim , 
	
		$lf->LoggerStringToFile( "****** Multiple Outpit Dirs detected with delim , : $OutputDir ******" );
		
		@output_dirs = split /,/, $OutputDir;
			
	}
	else {
	
		$lf->LoggerStringToFile( "****** Single directory passed (without delim ,) : $OutputDir ******" );
	
		@output_dirs = split /,/, $OutputDir;
	}
	
	my $l = 1; 
	
	if(defined($DataDir)) {
		while(defined($file = $DataDir->read())) {
			next if  ($file !~ /$FileMask/);
			next if  (!-f $InputDir.$file);
			chomp($file);
			if ( $FileDateCheck eq 'Y' && $between_dates_check != 0 ) {
			
				my @st_dc = stat($InputDir.$file);
				my $dt_epoch = $st_dc[9];
				my $dt_datetimeEpoch = DateTime->from_epoch(epoch => $dt_epoch);
				$dt_datetimeEpoch -> set_time_zone( 'local' );
				$dt_datetimeEpoch-> truncate ( to => "$expected_format_1");
				
				#print $first_between_date."\n";
				#print $second_between_date."\n";
				#print $between_dates_check."\n";
				#print $dt_datetimeEpoch."\n";
				
				if ( $between_dates_check == 1){				
					next if ( $dt_datetimeEpoch < $first_between_date || $dt_datetimeEpoch > $second_between_date );						
				}
				elsif ( $between_dates_check == 2){
					next if ( $dt_datetimeEpoch != $first_between_date );					
				}
			}
			
			#print $file."\n";
			
			$ARR->{$file}{Size} = -s ($InputDir.$file);
			$lf->LoggerStringToFile( "$file" );
		}

	if ($SizeCheck eq 'Y') {
			
				$lf->LoggerStringToFile( "****** Size Check Enabled entering sub for CheckSize ******" );
				sleep(20); #Maybe do it as input param also? Left 20 sec default time;
				@ARR_files_size = CheckSize($InputDir,$ARR); #Call sub SizeCheck	
			}
	elsif ($SizeCheck eq 'N') {
			
				$lf->LoggerStringToFile( "****** Size Check Disabled ******" );
			
		}
	elsif ($SizeCheck ne 'Y' && $SizeCheck ne 'N'){
		
				$lf->LoggerStringToFile( "****** Size Check Param wierd: $SizeCheck. Please check ******" );
		
		}
	if ($CtlFileCheck eq 'Y') {
	
				$lf->LoggerStringToFile( "****** Ctl Check Enabled entering sub for CtlFileCheck ******" );
				@ARR_ctl_check = CtlCheck($InputDir,$ARR,$CtlFileExtension); #Call sub CtlCheck
				
		}
	elsif ($CtlFileCheck eq 'N') {
		
				$lf->LoggerStringToFile( "****** Ctl Check Disabled ******" );
		
		}
	elsif ($CtlFileCheck ne 'Y' && $CtlFileCheck ne 'N'){
		
				$lf->LoggerStringToFile( "****** Ctl Check Param wierd: $CtlFileCheck. Please check ******" );
		
		}		
	if ($GzipInput eq 'Y'){
				
		$lf->LoggerStringToFile( "****** GzipInput Enabled ******" );
				
	}
	elsif ($GzipInput eq 'N'){
				
		$lf->LoggerStringToFile( "****** GzipInput Disabled ******" );
					
	}
	elsif ($GzipInput ne 'Y' && $GzipInput ne 'N'){
						
		$lf->LoggerStringToFile( "****** GzipInput Param wierd: $GzipInput. Please check ******" );
				
	}
	if ($GzipOutput eq 'Y'){
				
		$lf->LoggerStringToFile( "****** GzipOutput Enabled ******" );
				
	}
	elsif ($GzipOutput eq 'N'){
				
		$lf->LoggerStringToFile( "****** GzipOutput Disabled ******" );
					
	}
	elsif ($GzipOutput ne 'Y' && $GzipOutput ne 'N'){
						
		$lf->LoggerStringToFile( "****** GzipOutput Param wierd: $GzipOutput. Please check ******" );
				
	}
	if ($KeepInput eq 'Y'){
				
		$lf->LoggerStringToFile( "****** KeepInput Enabled ******" );
				
	}
	elsif ($KeepInput eq 'N'){
				
		$lf->LoggerStringToFile( "****** KeepInput Disabled ******" );
					
	}
	elsif ($KeepInput ne 'Y' && $KeepInput ne 'N'){
						
		$lf->LoggerStringToFile( "****** KeepInput Param wierd: $KeepInput. Please check ******" );
				
	}
######################################## Do Intersect of all avaible arrays 2 : @ARR_files_size	& @ARR_ctl_check ################################ 

	if ( !@ARR_files_size && !@ARR_ctl_check && ($CtlFileCheck eq 'N' && $SizeCheck eq 'N')){ #Both empty	
		foreach my $key (keys %$ARR){
		
			push @ARR_rdy_files, $key;
		
		}
	}
	elsif( ( !@ARR_files_size && $SizeCheck eq 'N' ) && @ARR_ctl_check ){ #Size check Empty set to N
	
		@ARR_rdy_files = @ARR_ctl_check;
	
	}
	elsif( @ARR_files_size && ( !@ARR_ctl_check && $CtlFileCheck eq 'N' ) ){ #Ctl check Empty set to N
	
		@ARR_rdy_files = @ARR_files_size;
	
	}
	elsif ( @ARR_files_size && @ARR_ctl_check && $SizeCheck eq 'Y' && $CtlFileCheck eq 'Y'){ #both filled 
	
		@ARR_rdy_files = intersect(@ARR_files_size, @ARR_ctl_check);
	
	}	

######################################## RUN trough Output Dir copy files dor file work ################################
	foreach my $output_dir (@output_dirs){

				chomp ($output_dir);
				$l++;
				foreach my $file_to_move (@ARR_rdy_files){

					$lf->LoggerStringToFile( "File $file_to_move creation/modification date (before transfer): ".EpochToString( (stat($InputDir.$file_to_move))[9] )." -> transferring to $output_dir" );

					my $copy_ok = CopyFile($InputDir,$output_dir,$file_to_move); #Copy file

					if ($copy_ok && $GzipInput eq 'Y'){
						$copy_ok = GzipInput($output_dir,$file_to_move);
					}
					if ($copy_ok && $GzipOutput eq 'Y'){
						$copy_ok = GunzipOutput($output_dir,$file_to_move);
					}
					$failed_files{$file_to_move} = 1 if !$copy_ok;					
			}
		}	
	}
	
	if ($ArchiveCheck eq 'Y'){
	
		$lf->LoggerStringToFile( "****** ArchiveCheck enabled entering arch sub ******" );
		$failed_files{$_} = 1 foreach ArchDo($InputDir,$ArchiveDir,grep { !$failed_files{$_} } @ARR_rdy_files);
	
	}
	
	foreach my $file_to_move (@ARR_rdy_files){
	
		if ($KeepInput eq 'N'){
					
			if ($failed_files{$file_to_move}){
				$lf->LoggerStringToFile( "File $InputDir$file_to_move was NOT deleted from input because it was not transferred successfully" );
				next;
			}
			KeepInput($InputDir,$file_to_move);
			
			if ($CtlFileCheck eq 'Y'){
				my $filefin_no_ext = $file_to_move;
				$filefin_no_ext = substr $filefin_no_ext, 0, rindex( $filefin_no_ext, q{.} );
				
				KeepInput($InputDir,$filefin_no_ext.".".$CtlFileExtension);
			}					
		}
	
	}
	
	$lf->LoggerStringToFile( "****** END Transit files ******" );
}
######### GetFiles Remote Subs and build; #########

sub GetFilesRemote() {

	#my $SftpType 			= shift;
	#my $SftpPassFile 	= shift;
	#my $SftpKey 			= shift;
	#my $SftpHost 			= shift;
	#my $SftpUser 			= shift;
	my $sftp1					= shift;
	
	my $InputDir 			= shift;
	my $OutputDir 			= shift;
	my $FileMask 			= shift;
	
	my @output_dirs				   ;
	my %failed_files; # files that were NOT transferred completely - these must never be deleted from input
	my $l = 1					   		   ;

	$lf->LoggerStringToFile( "****** START SFTP Transit files ******" );
	$lf->LoggerStringToFile( "****** Param is as following : InputDir = $InputDir; OutputDir = $OutputDir; Searching FileMask = $FileMask; ******" );
	
		if ($OutputDir =~ /,/){ #Hardcoded Delim , 
	
		$lf->LoggerStringToFile( "****** Multiple Outpit Dirs detected with delim , : $OutputDir ******" );
		
		@output_dirs = split /,/, $OutputDir;
			
	}
	else {
	
		$lf->LoggerStringToFile( "****** Single directory passed (without delim ,) : $OutputDir ******" );
	
		@output_dirs = split /,/, $OutputDir;
	}
	
	
	
	my @sftp_files = $sftp1->ls($InputDir);
	my $ARR;
	my %ARR;
	my @ARR_files_size;
	my @ARR_ctl_check;
	my @ARR_rdy_files						 ;
	
	
	
	if (!@sftp_files){
	
		$lf->LoggerStringToFile("****** Nothing collected pls check input dir : $InputDir is it correct ******");
		
	}
	
	foreach  my $sftp_file (@sftp_files) { 
		foreach my $file (@$sftp_file){
		
			next if !IsRemoteRegularFile($sftp1,$InputDir,$file); # ls also returns ".", ".." and directories

			if  ($file->{'filename'} =~ $FileMask ){				
				if ( $FileDateCheck eq 'Y' && $between_dates_check != 0 ) {
				
					my ($sec_sftp,$min_sftp,$hour_sftp,$mday_sftp,$mon_sftp,$year_sftp) = localtime($file->{'a'}{'mtime'});
					$year_sftp = sprintf("%02d", $year_sftp+1900);
					$mon_sftp = sprintf("%02d", $mon_sftp+1);
					$mday_sftp = sprintf("%02d", $mday_sftp);
					$hour_sftp = sprintf("%02d", $hour_sftp);
					$min_sftp = sprintf("%02d", $min_sftp);
					$sec_sftp = sprintf("%02d", $sec_sftp);
					my $mtime =  "$year_sftp"."$mon_sftp"."$mday_sftp"." $hour_sftp"."$min_sftp"."$sec_sftp";

					my $dt_epoch = str2time($mtime);
					my $dt_datetimeEpoch = DateTime->from_epoch(epoch => $dt_epoch);
					$dt_datetimeEpoch -> set_time_zone( 'local' );
					$dt_datetimeEpoch-> truncate ( to => "$expected_format_1");
					if ( $between_dates_check == 1){				
						next if ( $dt_datetimeEpoch < $first_between_date || $dt_datetimeEpoch > $second_between_date );							
					}
					elsif ( $between_dates_check == 2){
						next if ( $dt_datetimeEpoch != $first_between_date );
						
					}
				}
				my $local_file = "$file->{'filename'}";
				my $local_size = $file->{'a'}{'size'};
				my $local_mtime = $file->{'a'}{'mtime'};

				chomp($local_file);
				chomp($local_size);

				$ARR->{"$local_file"}{size}  = $local_size;
				$ARR->{"$local_file"}{mtime} = $local_mtime;

				$lf->LoggerStringToFile( "$local_file" );
			
			}		
		}
	}
	
	if ($SizeCheck eq 'Y') {
			
				$lf->LoggerStringToFile( "****** Size Check Enabled entering sub for CheckSize by SFTP ******" );
				sleep(20); #Maybe do it as input param also? Left 20 sec default time;
				@ARR_files_size = CheckSize_Sftp($InputDir,$ARR,$sftp1); #Call sub SizeCheck	
	}
	elsif ($SizeCheck eq 'N') {
			
				$lf->LoggerStringToFile( "****** Size Check Disabled ******" );
			
	}
	elsif ($SizeCheck ne 'Y' && $SizeCheck ne 'N'){
		
				$lf->LoggerStringToFile( "****** Size Check Param wierd: $SizeCheck. Please check ******" );
		
	}
	
	if ($CtlFileCheck eq 'Y') {
	
				$lf->LoggerStringToFile( "****** Ctl Check Enabled entering sub for CtlFileCheck SFTP******" );
				@ARR_ctl_check = CtlCheck_Sftp($InputDir,$ARR,$CtlFileExtension,$sftp1); #Call sub CtlCheck
				
				
	}
	elsif ($CtlFileCheck eq 'N') {
		
				$lf->LoggerStringToFile( "****** Ctl Check Disabled ******" );
		
	}
	elsif ($CtlFileCheck ne 'Y' && $CtlFileCheck ne 'N'){
		
				$lf->LoggerStringToFile( "****** Ctl Check Param wierd: $CtlFileCheck. Please check ******" );
		
	}	
		if ($GzipInput eq 'Y'){
				
		$lf->LoggerStringToFile( "****** GzipInput Enabled ******" );
				
	}
	elsif ($GzipInput eq 'N'){
				
		$lf->LoggerStringToFile( "****** GzipInput Disabled ******" );
					
	}
	elsif ($GzipInput ne 'Y' && $GzipInput ne 'N'){
						
		$lf->LoggerStringToFile( "****** GzipInput Param wierd: $GzipInput. Please check ******" );
				
	}
	if ($GzipOutput eq 'Y'){
				
		$lf->LoggerStringToFile( "****** GzipOutput Enabled ******" );
				
	}
	elsif ($GzipOutput eq 'N'){
				
		$lf->LoggerStringToFile( "****** GzipOutput Disabled ******" );
					
	}
	elsif ($GzipOutput ne 'Y' && $GzipOutput ne 'N'){
						
		$lf->LoggerStringToFile( "****** GzipOutput Param wierd: $GzipOutput. Please check ******" );
				
	}
	if ($KeepInput eq 'Y'){
				
		$lf->LoggerStringToFile( "****** KeepInput Enabled ******" );
				
	}
	elsif ($KeepInput eq 'N'){
				
		$lf->LoggerStringToFile( "****** KeepInput Disabled ******" );
					
	}
	elsif ($KeepInput ne 'Y' && $KeepInput ne 'N'){
						
		$lf->LoggerStringToFile( "****** KeepInput Param wierd: $KeepInput. Please check ******" );
				
	}
######################################## Do Intersect of all avaible arrays 2 : @ARR_files_size	& @ARR_ctl_check ################################	
	if ( !@ARR_files_size && !@ARR_ctl_check ){ #Both empty	
		foreach my $key (keys %$ARR){
		
			push @ARR_rdy_files, $key;
		
		}
	}
	elsif( ( !@ARR_files_size && $SizeCheck eq 'N' ) && @ARR_ctl_check ){ #Size check Empty set to N
	
		@ARR_rdy_files = @ARR_ctl_check;
	
	}
	elsif( @ARR_files_size && ( !@ARR_ctl_check && $CtlFileCheck eq 'N' ) ){ #Ctl check Empty set to N
	
		@ARR_rdy_files = @ARR_files_size;
	
	}
	elsif ( @ARR_files_size && @ARR_ctl_check && $SizeCheck eq 'Y' && $CtlFileCheck eq 'Y'){ #both filled 
	
		@ARR_rdy_files = intersect(@ARR_files_size, @ARR_ctl_check);
	
	}
######################################## RUN trough Output Dir copy files dor file work ################################
	foreach my $output_dir (@output_dirs){

				chomp ($output_dir);
				$l++;
				foreach my $file_to_move (@ARR_rdy_files){

					$lf->LoggerStringToFile( "File $file_to_move creation/modification date (before transfer): ".EpochToString( $ARR->{$file_to_move}{mtime} )." -> transferring to $output_dir" );

					my $copy_ok = CopyFile_Sftp($InputDir,$output_dir,$file_to_move,$sftp1);

					if ($copy_ok && $GzipInput eq 'Y'){
						$copy_ok = GzipInput($output_dir,$file_to_move);
					}
					if ($copy_ok && $GzipOutput eq 'Y'){
						$copy_ok = GunzipOutput($output_dir,$file_to_move);
					}
					$failed_files{$file_to_move} = 1 if !$copy_ok;					
			}
		}
		if ($ArchiveCheck eq 'Y'){
	
		$lf->LoggerStringToFile( "****** ArchiveCheck enabled entering arch sub ******" );
		$failed_files{$_} = 1 foreach ArchDo_Sftp($InputDir,$ArchiveDir,$sftp1,grep { !$failed_files{$_} } @ARR_rdy_files);
	
	}
	
	foreach my $file_to_move (@ARR_rdy_files){
	
		if ($KeepInput eq 'N'){
					
			if ($failed_files{$file_to_move}){
				$lf->LoggerStringToFile( "File $InputDir$file_to_move was NOT deleted from input because it was not transferred successfully" );
				next;
			}
			KeepInput_Sftp($InputDir,$file_to_move,$sftp1);
			if ($CtlFileCheck eq 'Y'){
				my $filefin_no_ext = $file_to_move;
				$filefin_no_ext = substr $filefin_no_ext, 0, rindex( $filefin_no_ext, q{.} );
				
				KeepInput_Sftp($InputDir,$filefin_no_ext.".".$CtlFileExtension,$sftp1);
			}					
		}	
	}
	
	$lf->LoggerStringToFile( "****** END Transit files SFTP ******" );
	
}

######### AUX Subs and build; #########

# Format an epoch timestamp (e.g. a file's mtime) as YYYY-MM-DD HH:MM:SS in local time.
# Used to log when a file was created/last modified before it is transferred.
sub EpochToString() {

	my $epoch = shift;
	return 'unknown' unless ( defined $epoch && $epoch =~ /^\d+$/ );

	my ($sec,$min,$hour,$mday,$mon,$year) = localtime( $epoch );
	return sprintf( "%04d-%02d-%02d %02d:%02d:%02d",
		$year+1900, $mon+1, $mday, $hour, $min, $sec );

}

# True only for regular files. SFTP ls() also returns ".", ".." , directories and special entries;
# symlinks are followed and accepted when they point to a regular file.
sub IsRemoteRegularFile {

	my $sftp1	= shift;
	my $dir		= shift;
	my $entry	= shift;

	my $name = $entry->{'filename'};
	return 0 if ( !defined $name || $name eq '' || $name eq '.' || $name eq '..' );

	my $perm = $entry->{'a'}{'perm'};
	if ( !defined $perm ){ # server sent no permissions, fall back to the ls -l style line
		my $kind = substr( ( defined $entry->{'longname'} ? $entry->{'longname'} : '' ), 0, 1 );
		return 1 if $kind eq '-';
		if ( $kind ne 'l' ){
			$lf->LoggerStringToFile( "Skipping $dir$name, it is not a regular file" ) if $kind eq 'd';
			return 0;
		}
	}
	elsif ( S_ISREG($perm) ){
		return 1;
	}
	elsif ( S_ISDIR($perm) ){
		$lf->LoggerStringToFile( "Skipping directory $dir$name (set SubDirCheck:Y to process sub-directories)" );
		return 0;
	}
	elsif ( !S_ISLNK($perm) ){
		$lf->LoggerStringToFile( "Skipping $dir$name, it is not a regular file" );
		return 0;
	}

	# symlink: look at what it points to
	my $target = $sftp1->stat( "$dir$name" );
	if ( $target && defined $target->{'perm'} && S_ISREG( $target->{'perm'} ) ){
		return 1;
	}
	$lf->LoggerStringToFile( "Skipping $dir$name, it is a symbolic link that does not point to a regular file" );
	return 0;

}

# Log an error AND queue it for the notification e-mail (sent at exit when Notification:Y).
sub ReportError {

	my $text = shift;
	$lf->LoggerStringToFile( "ERROR: $text" );

	(my $html = $text) =~ s/&/&amp;/g;
	$html =~ s/</&lt;/g;
	$html =~ s/>/&gt;/g;
	push (@message, "ERROR: $html") && push (@message, '<br>');
	return 1;

}

# Returns 1 when the file is complete in the target directory, 0 otherwise (nothing half-written is left behind).
sub CopyFile_Sftp {

	my $InputDir 			= shift;
	my $OutputDir			= shift;
	my $File				= shift;
	my $sftp1 				= shift;
	
	my $tmp_file   = $OutputDir."tmp_".$File;
	my $final_file = $OutputDir.$File;

	if( !$sftp1->get("$InputDir$File",$tmp_file) ){
		ReportError( "Can't copy $InputDir$File to $OutputDir from SFTP: ".$sftp1->error );
		unlink $tmp_file;
		return 0;
	}

	$lf->LoggerStringToFile( "File $InputDir$File downloaded to $tmp_file" );
	if( !move( $tmp_file, $final_file ) ){
		ReportError( "Can't rename $tmp_file to $final_file: $!" );
		unlink $tmp_file;
		return 0;
	}

	$lf->LoggerStringToFile( "File $tmp_file renamed to $final_file" );
	#system( "chmod 777 $ToDir/$uncompressed_file.DAT 1>/dev/null 2>/dev/null" ); left for chmod purposes see if needed?
	return 1;
}

# Returns the files that could NOT be archived.
sub ArchDo_Sftp {

	my $InputDir 			= shift;
	my $ArchiveDir			= shift;
	my $sftp1 				= shift;
	my @ARR1_to_arch		= @_; 
	my @failed;
	
	foreach my $File (@ARR1_to_arch){
	
		if( !$sftp1->get("$InputDir$File","$ArchiveDir$File")) {
			ReportError( "Can't copy $InputDir$File to $ArchiveDir SFTP: ".$sftp1->error );
			push @failed, $File;
		}
		else {
			$lf->LoggerStringToFile( "File $InputDir$File archived to $ArchiveDir$File" );
		}
	}

	return @failed;
}

sub KeepInput_Sftp {

	my $InputDir 			= shift;
	my $File				= shift;
	my $sftp1				= shift;

	if( !$sftp1->remove("$InputDir$File")) {
		ReportError( "Can't delete $InputDir$File SFTP: ".$sftp1->error );
		return 0;
	}
	return 1;
}

sub CheckSize_Sftp() {

	my $InputDir 			= shift;
	my $ARR1				= shift;
	my $sftp1				= shift;
	
	my @ARR_files1				   ;
	my @sftp_files1 = $sftp1->ls($InputDir);

	foreach  my $sftp_file1 (@sftp_files1) {
		foreach my $file1 (@$sftp_file1){ 
			
			if ($ARR1->{$file1->{'filename'}} && $ARR1->{$file1->{'filename'}}{size} eq $file1->{'a'}{'size'}){
				
				push @ARR_files1, $file1->{'filename'};
			
			}
		}
	}

	return @ARR_files1;
	
}
sub CtlCheck_Sftp(){

	my $InputDir 						= shift;
	my $ARR1							= shift;
	my $CtlFileExtension			= shift;
	my $sftp1							= shift;
	
	my @ARR_files1				   ;
	my $l = 0;
	
	my @sftp_files1 = $sftp1->ls($InputDir);
	
	foreach  my $sftp_file1 (@sftp_files1) {
		foreach my $file1 (@$sftp_file1){ 
		
			my @pieces;
			push ( @pieces, $_ ) foreach split( /\./, $file1->{'filename'} );
			if ($pieces[-1] eq $CtlFileExtension){
				my $file1_no_ext = "$file1->{'filename'}";
				$file1_no_ext = substr $file1_no_ext, 0, rindex( $file1_no_ext, q{.} );
					foreach my $key (keys %$ARR1){
						my $key_no_ext = $key;
						$key_no_ext = substr $key_no_ext, 0, rindex( $key_no_ext, q{.} );
						
						if ($file1_no_ext eq $key_no_ext){						
							push @ARR_files1, $key;						
						}
					}				
			}
		}
	}

	return @ARR_files1;

}

sub CheckSize() { 

	my $InputDir 			= shift;
	my $ARR1				= shift;
	
	my $DataDir1 = DirHandle->new("$InputDir");
	
	my $file1					   ;
	my @res1					   ;
	my @ARR_files1				   ;
	
	while( defined($file1 = $DataDir1->read())) {
		foreach my $key (keys %$ARR1){
			if ($file1 eq $key){

				my $cur_size = -s ($InputDir.$file1);
				if ( defined $cur_size && $cur_size == $ARR1->{$key}{Size} ){


					push @ARR_files1, $file1;

				}
			}
		}
	}
	
	return @ARR_files1;
	
}

sub CtlCheck() { 

	my $InputDir 			= shift;
	my $ARR1				= shift;
	my $CtlMask				= shift;
	
	my $DataDir1 = DirHandle->new("$InputDir");
	
	my $file1					   ;
	my @ARR_files1				   ;
	my $l = 0;
	
	while( defined($file1 = $DataDir1->read())) {
	
		
		if (-f $file1){
			my @pieces;

			push ( @pieces, $_ ) foreach split( /\./, $file1 );

			
			if ($pieces[-1] eq $CtlMask){

				foreach my $key (keys %$ARR1){
					my $file1_no_ext = $file1;
					$file1_no_ext = substr $file1_no_ext, 0, rindex( $file1_no_ext, q{.} );
					my $key_no_ext = $key;
					$key_no_ext = substr $key_no_ext, 0, rindex( $key_no_ext, q{.} );		

					if ($file1_no_ext eq $key_no_ext){

						push @ARR_files1, $key;
						
					}			
				}		
			}		
		}
	}	
	
	return @ARR_files1;

}

# Returns the files that could NOT be archived.
sub ArchDo {

	my $InputDir 			= shift;
	my $ArchiveDir			= shift;
	my @ARR1_to_arch		= @_; 
	my @failed;
	
	foreach my $File (@ARR1_to_arch){
	
		if( !copy("$InputDir$File","$ArchiveDir$File" ) ) {
			ReportError( "Can't copy $InputDir$File to $ArchiveDir: $!" );
			push @failed, $File;
		}
		else {
			$lf->LoggerStringToFile( "File $InputDir$File archived to $ArchiveDir$File" );
		}
	}

	return @failed;
}

# Return 1 on success, 0 on failure.
sub GzipInput { #will compress Lempel-Ziv (LZ77)

	my $InputDir 			= shift;
	my $File				= shift;
	
	if( system( 'gzip', '-f', "$InputDir$File" ) != 0 ){ #Left force for the command will overwrite all existing files check if it is ok;
		ReportError( "gzip of $InputDir$File failed (exit status ".($? >> 8).")" );
		return 0;
	}
	return 1;
}

sub GunzipOutput { #willUncompress.

	my $InputDir 			= shift;
	my $File				= shift;

	if( system( 'gunzip', '-f', "$InputDir$File" ) != 0 ){ #Left force for the command will overwrite all existing files check if it is ok;
		ReportError( "gunzip of $InputDir$File failed (exit status ".($? >> 8).")" );
		return 0;
	}
	return 1;
}

# Returns 1 when the file is complete in the target directory, 0 otherwise (nothing half-written is left behind).
sub CopyFile {
	
	my $InputDir 			= shift;
	my $OutputDir			= shift;
	my $File				= shift;
	
	my $tmp_file   = $OutputDir."tmp_".$File;
	my $final_file = $OutputDir.$File;

	if( !copy("$InputDir$File",$tmp_file ) ) {
		ReportError( "Can't copy $InputDir$File to $OutputDir: $!" );
		unlink $tmp_file;
		return 0;
	}

	$lf->LoggerStringToFile( "File $InputDir$File copied to $tmp_file" );
	if( !move( $tmp_file, $final_file ) ){
		ReportError( "Can't rename $tmp_file to $final_file: $!" );
		unlink $tmp_file;
		return 0;
	}

	$lf->LoggerStringToFile( "File $tmp_file renamed to $final_file" );
	#system( "chmod 777 $ToDir/$uncompressed_file.DAT 1>/dev/null 2>/dev/null" ); left for chmod purposes see if needed?
	return 1;
}

sub KeepInput {

	my $InputDir 			= shift;
	my $File				= shift;

	if( !unlink $InputDir.$File ) {
		ReportError( "Can't delete $InputDir$File: $!" );
		return 0;
	}
	return 1;
}

sub Notification() {

	my $sender				= shift;
	my $recipient			= shift;
	my $cc_recipient		= shift;

	my @message				= @_; 

	# which machine ran the script and, for SFTP jobs, which server it talked to
	my $run_host	= hostname();
	my $transfer	= ( defined $SftpCheck && $SftpCheck eq 'Y' )
		? "SFTP from server ".$SftpHost." (user ".$SftpUser.")"
		: "local transfer";
	my $server_info = "Script ran on server: <b>$run_host</b><br>\n\tTransfer: $transfer<br>\n\tParam file: $param_file<br>\n\tInput dir: $InputDir; Output dir: $OutputDir<br>";

	my  $msg = MIME::Lite->new(
        From    => $sender,
        To      => $recipient,
        Cc      => $cc_recipient,
        Subject => "Automatic Mail from : File transfer with param $param_file on ".hostname(),
        Type    => 'multipart/mixed'
		);
    $msg->attr('content-type.charset' => "utf-8");
	$msg->attach(      
	Type => 'text/html',
	Data     => "<!DOCTYPE html>
	<html lang=\"bg\">
	<head>
	<meta charset=\"utf-8\">
	<title>Automatic File Transfer Notification</title>
	<style>
	p.v1 {
    font: 7px arial, sans-serif;
	}

	table, th, td {
    border: 1px solid black;
	border-collapse: collapse;
	}
	th, td {
    padding: 5px;
	}
	img { 
    width:10%; 
	}
	table tr:nth-child(even){
	background-color: #f2f2f2;
	}

	</style>
	</head>
	<body>
	Hi,<br>
	This is an automatic notification from file_tran.pl  <br>
	$server_info<br>
	@message
	<br>
	Please do not replay if not needed. <br>
	Cheers <br>
file_tran.pl


<p class=\"v1\"> v.$script_version </p>



</body>
</html>
"
);
	
$msg->send($NotificationMethod,$NotificationServer, 	Debug=>0 )if (@message);
	
}
