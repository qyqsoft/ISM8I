#!/usr/bin/perl
#
#  $Id: 15_WOLF_ISM8I.pm 
#######################################################################################################
#  WOLF_ISM8I
# 
#  Erstellt von: Dr. Mugur Dietrich
#  E-Mail: m punkt i punkt dietrich at gmx punkt de
#
#  Beschreibung:
#  FHEM Modul zur Komunikation mit dem Wolf Informations- und Schnittstellenmodul ISM8i.
#
#######################################################################################################

package main;

use strict;
use warnings;
use utf8;
use IO::Socket;
use IO::Socket::INET;
use threads;
use Thread::Queue;
use DevIo;

sub WOLF_ISM8I_Initialize($);
sub WOLF_ISM8I_Define($$);
sub WOLF_ISM8I_Undef($@);
sub WOLF_ISM8I_Read($);
sub WOLF_ISM8I_Set($@);
sub WOLF_ISM8I_Get($$@);
sub WOLF_ISM8I_Attr($@); 

sub WOLF_ISM8I_TimeoutFunction($); 

sub TcpServerOpen($$);
sub TcpServerAccept($$);
sub TcpServerClose($@);
sub ClientSocketClose($);
sub TcpCommunicationThread;
sub TimerStartOrUpdate($);
sub TimerKill($);

sub create_answer($@);
sub dataToHex($);
sub enqueReadings($$);
sub decodeThreadTelegram($@);
sub sendToThread($$);
sub countWolfReadings($);
sub deleteIgnores($);
sub loadDatenpunkte;
sub loadSetter;
sub getSetterWidget($$);
sub dec2ip($);
sub ip2dec($);
sub r_trim;
sub l_trim;
sub all_trim;
sub dbl_trim;
sub l_r_dbl_trim;
sub find_reading_on_dp($$); 

sub getFhemFriendly($);
sub getFhemInOut($);
sub getDatenpunkt($$);
sub getCsvResult($$);

sub codeSetting($$);
sub codeValueByType($$);
sub convert_NumberToChars($$);
sub getLen($);

sub convert_DptFloatToNumber($);
sub convert_NumberToDptFloat($);
sub convert_DptLongToNumber($);
sub convert_DptScalingToNumber($);
sub convert_NumberToDptScaling($);

sub convert_DptTimeToString($);
sub convert_StringToDptTime_DayOnly($);
sub convert_StringToDptTime_TimeOnly($);
sub convert_DptDateToString($);
sub convert_StringToDptDate($);

sub getBitweise($$$);
sub setBitwise($$$);
sub getByteweise($$);


###############################################################
#                  Globale Variablen
###############################################################

my @datenpunkte;
my @writepunkte;
my %sets;
my @clients = ();
my $dataQueue = Thread::Queue->new();
my $sendToThreadQueue = Thread::Queue->new();
my $qSplitter = chr(0x02).chr(0x03).chr(0x04);

 
###############################################################
#                  WOLF_ISM8I_Initialize
###############################################################
sub WOLF_ISM8I_Initialize($) 
{
  my ($hash) = @_;

  $hash->{DefFn}      = "WOLF_ISM8I_Define";
  $hash->{UndefFn}    = "WOLF_ISM8I_Undef";
  $hash->{ReadFn}     = "WOLF_ISM8I_Read";
  $hash->{SetFn}      = "WOLF_ISM8I_Set";
  $hash->{AttrFn}     = "WOLF_ISM8I_Attr";
  $hash->{GetFn}      = "WOLF_ISM8I_Get";

  #$hash->{ReadyFn}    = "WOLF_ISM8I_Ready";
  #$hash->{WriteFn}    = "WOLF_ISM8I_Write";
  
  $hash->{CanAuthenticate} = 0;
  
  
  #Attribute für WOLF_ISM8I_Attr
  no warnings 'qw';
  my @attrList = qw(
    ignoreDatapoints
	showDebugData:0,1
	forewardAddress
  );
  use warnings 'qw';
  $hash->{AttrList} = join(" ", @attrList)." ".$readingFnAttributes;
 
  loadDatenpunkte; # Läd ./FHEM/wolf_datenpunkte_15.csv
  loadSetter; # Läd ./FHEM/wolf_writepunkte_15.csv
}


###############################################################
#                  WOLF_ISM8I_Define
###############################################################
sub WOLF_ISM8I_Define($$)
{
  my ($hash, $def) = @_;
  my ($name, $type, $port) = split("[ \t]+", $def);
  return "Usage: define <name> WOLF_ISM8I tcp-portnr>" if($port !~ m/^\d+$/);
  
  # Default Attribute setzen falls Attribute leeer oder nicht vorhanden:
  if (AttrVal($name, "showDebugData", "empty") eq "empty") { $attr{$name}{"showDebugData"} = "0"; }
  if (AttrVal($name, "event-on-change-reading", "empty") eq "empty") { $attr{$name}{"event-on-change-reading"} = ".*"; }

  WOLF_ISM8I_Undef($hash, undef) if($hash->{OLDDEF}); # modify
  my $ret = TcpServerOpen($hash, $port);

  # Make sure that fhem only runs once
  if($ret && !$init_done) {
    Log3 $name, 1, "$ret. Exiting.";
    exit(1);
  }
  $hash->{clients} = {};
  $hash->{retain} = {};

  deleteIgnores($hash);

  return $ret;
}


###############################################################
#                  WOLF_ISM8I_Undef
###############################################################
sub WOLF_ISM8I_Undef($@)
{
   my ($hash, $arg) = @_;
  
   foreach ( @clients ) { 
      $_->kill('KILL')->detach;
      if( $_->is_joinable() ) { $_->join(); } 
   }

   TimerKill($hash);

   my $ret = TcpServerClose($hash);
   my $sname = $hash->{SNAME};
   return undef if(!$sname);

   my $shash = $defs{$sname};
   delete($shash->{clients}{$hash->{NAME}});

   return $ret;
}
  

###############################################################
#                  WOLF_ISM8I_Read
###############################################################
sub WOLF_ISM8I_Read($)
{
   my ($hash) = @_;
   my $name = $hash->{NAME};
   
   if (ReadingsVal($name, "_WOLF_READINGS_COUNT", 0) == 0) {
      readingsSingleUpdate($hash, "_WOLF_READINGS_COUNT", countWolfReadings($hash), 1);
   }

   if( $hash->{SERVERSOCKET} ) { 
     TimerStartOrUpdate($hash);
     push ( @clients, threads->create(\&TcpCommunicationThread, $hash) );
     foreach ( @clients ) { if( $_->is_joinable() ) { $_->join(); } }
   }
	
   return;
}


###############################################################
#                  WOLF_ISM8I_TimeoutFunction
###############################################################
#Ist die Hauptfunktion zum anzeigen der Readings die im Thread 
#enqued wurden. Durch den InternalTimer aufgerufen. Verarbeitet 
#die Readings aus dem Thread.
###############################################################
sub WOLF_ISM8I_TimeoutFunction($) 
{
   my ($hash) = @_;
   my $name = $hash->{NAME};
   my ($deq, @field, $rc, $nc);
   my $upd = 0;
   my $ts = undef;

   while ($dataQueue->pending() > 0) {
      $deq = $dataQueue->dequeue_nb();
   	  @field = split(/$qSplitter/, $deq);
	 
	  if (scalar(@field) == 2) { 
	     readingsSingleUpdate($hash, "$field[0]", "$field[1]", 1); 
	     if ( ($field[0] !~ m/^_/) and ($field[0] ne "state") ) { $ts = TimeNow; $upd = 1; }
	  } 
   } 

   if ($upd == 1) { 
      # Anzahl der Wolf Readings ermitteln und ggf aktualisieren:
	  $rc = ReadingsVal($name, "_WOLF_READINGS_COUNT", 0);
	  $nc = countWolfReadings($hash);
	  if ($nc != $rc) { 
	     readingsSingleUpdate($hash, "_WOLF_READINGS_COUNT", "$nc", 1); 
	  }
  
      # Timestamp des letzten Wolf Readings:
      if ($ts) { 
	    readingsSingleUpdate($hash, "_WOLF_LAST_READING", "$ts", 1); 
	  }
   }
  
   TimerStartOrUpdate($hash); # hier am Ende stehen lassen!!!
}


###############################################################
#                  WOLF_ISM8I_Set
###############################################################
sub WOLF_ISM8I_Set($@)
{
   my ( $hash, $name, $cmd, @args ) = @_;
   my $arg = join("", @args);
   my $settings = join(" ", sort keys %sets);
   my $id = 0;   
   if ($cmd =~ /(\.)(\d{1,3})(\.)/) { $id = $2; }
   
   return "\"set $name\" needs at least one argument" unless (defined($cmd));
   return "Unknown argument '$cmd', choose one of $settings" unless (index($settings, $cmd) >= 0);

   if ($id > 0 and defined($arg)) {
      my $val = codeSetting($id, $arg);
      if (length($val) > 0) { 
         Log3 ($name, 5, "WOLF_ISM8I_Set: cmd -> $cmd / id -> $id / arg -> $arg");
         Log3 ($name, 5, "send telegram -> ".dataToHex($val));
         sendToThread("sendDatagramm", $val); 
	  }
   }
}


###############################################################
#                  WOLF_ISM8I_Get
###############################################################
sub WOLF_ISM8I_Get($$@)
{
   my ( $hash, $name, $opt, @args ) = @_;
 
   my %gets = ( 
     "ClearReadings:noArg"  => "noArg",
     "GetAllData:noArg"     => "noArg",
     "Reconnect:noArg"      => "noArg",
   );

   if ($opt eq "ClearReadings") {
      fhem("deletereading $name .*");; 
   }
   elsif ($opt eq "GetAllData") {
      my $getAll = chr(0x06).chr(0x20).chr(0xf0).chr(0x80).chr(0x00).chr(0x16).chr(0x04).chr(0x00).chr(0x00).chr(0x00).chr(0xf0).chr(0xd0);
      sendToThread("sendDatagramm", $getAll); 
   }
   elsif($opt eq "Reconnect") {
	  my $port = $hash->{PORT};
      WOLF_ISM8I_Undef($hash, undef);
      TcpServerOpen($hash, $port);
   }
   else {
	 return "Unknown argument $opt, choose one of " . join(" ", keys %gets)
   }
  
   return undef; 
}


###############################################################
#                  WOLF_ISM8I_Attr
###############################################################
sub WOLF_ISM8I_Attr($@)
{
  my ($cmd,$name,$aName,$aVal) = @_;
  my $hash = $defs{$name};
  my $dp;
  my $reading;
  my $i = 0;
  my @datapoints;
  
  # $cmd  - Vorgangsart - kann die Werte "del" (löschen) oder "set" (setzen) annehmen
  # $name - Gerätename
  # $aName / $aVal sind Attribut-Name und Attribut-Wert
  
  if ($aName eq "ignoreDatapoints" and length($aVal) > 0) {
	  $_[3] = l_r_dbl_trim($aVal); # Alle doppelte Leerzeichen/Tabs entfernen.
      $aVal = $_[3]; 
	  Log3 ($name, 5, "Ignore Attribute: $aVal");

      @datapoints = split(/ /, $aVal);
	  foreach $dp (@datapoints) {
	    if ($dp !~ m/^\d{1,3}$/) { return "$aName: $dp entspricht nicht den Vorgaben der Ignore Liste!"; }
		$i ++;
      }
	  
      if ($cmd eq "set" and $i > 0) {
	      readingsSingleUpdate($hash, "_WOLF_IGNORES_COUNT", "$i", 1); # Anzahl der Ignores angeben
		  foreach $dp (@datapoints) { 
            $reading = find_reading_on_dp($hash, $dp);
			if ( defined($reading) ) { fhem("deletereading $name $reading");; }
		  }
      } elsif ($cmd eq "del") {
	      readingsSingleUpdate($hash, "_WOLF_IGNORES_COUNT", "0", 1); # Anzahl der Ignores angeben
	  }
  }
   
  if ($aName eq "showDebugData") {
     if (($cmd eq "set" and $aVal == 0) or $cmd eq "del"){ 
	    fhem("deletereading $name _DBG.*");
		sendToThread("showDebugData", 0);
	 }
  }
  
  if ($aName eq "forewardAddress") {
	 if ($cmd eq "set" and length($aVal) > 0) {
	    $_[3] = all_trim($aVal); # Alle Whitespaces entfernen.
        $aVal = $_[3]; 
        sendToThread("forewardAddress", $aVal);
      } elsif ($cmd eq "del") {
		sendToThread("forewardAddress", "none");
	  }
  }
  
  return undef
}

#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#   Subs and Functions   ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

###############################################################
#                  TcpServerOpen
###############################################################
sub TcpServerOpen($$)
{
  my ($hash, $port) = @_;
  my $name = $hash->{NAME};
  my @opts = (
      LocalHost => "0.0.0.0",
      LocalPort => $port,
      Proto     => "tcp",
      Listen    => 32,
      ReuseAddr => 1
  );	#  Blocking  => 1,

  
  readingsSingleUpdate($hash, "state", "Initialized", 0);
  
  $hash->{SERVERSOCKET} = IO::Socket::INET->new(@opts);

  if(!$hash->{SERVERSOCKET}) {
    return "$name: Can't open server port at $port: $!";
  }

  $hash->{SERVERSOCKET}->autoflush(1);
  $hash->{FD} = $hash->{SERVERSOCKET}->fileno();
  $hash->{PORT} = $hash->{SERVERSOCKET}->sockport();

  $selectlist{"$name.$port"} = $hash;
  Log3 $hash, 3, "$name: port ". $hash->{PORT} ." opened";
  return undef;
}


###############################################################
#                  TcpServerAccept
###############################################################
sub TcpServerAccept($$)
{
  my ($hash, $type) = @_;
  my $name = $hash->{NAME};

  my @clientinfo = $hash->{SERVERSOCKET}->accept();
  if(!@clientinfo) {
    Log3 $name, 3, "Accept failed ($name: $!)" if($! != EAGAIN);
    return undef;
  }
  
  #$clientinfo[0]->blocking(0);  # Forum #24799
  
  $hash->{CONNECTS}++;

  my ($port, $iaddr) = sockaddr_in($clientinfo[1]);
  my $caddr = inet_ntoa($iaddr);
  my $cname = "${name}_${caddr}_${port}";
  my %nhash;
  
  $nhash{NR}    = $devcount++;
  $nhash{NAME}  = $cname;
  $nhash{PEER}  = $caddr;
  $nhash{PORT}  = $port;
  $nhash{FD}    = $clientinfo[0]->fileno();
  $nhash{CD}    = $clientinfo[0];     # sysread / close won't work on fileno
  $nhash{TYPE}  = $type;
  $nhash{SNAME} = $name;
  $nhash{TEMPORARY} = 1;              # Don't want to save it
  $nhash{BUF}   = "";
  
  readingsSingleUpdate($hash, "state", "Connected", 0);
  
  $attr{$cname}{room} = "hidden";
  $defs{$cname} = \%nhash;
  $selectlist{$nhash{NAME}} = \%nhash;

  my $ret = $clientinfo[0]->setsockopt(SOL_SOCKET, SO_KEEPALIVE, 1);

  Log3 $name, 4, "Connection accepted from $nhash{NAME}";
  return \%nhash;
}


###############################################################
#                  TcpServerClose
###############################################################
sub TcpServerClose($@)
{
  my ($hash, $dodel) = @_;
  my $name = $hash->{NAME};

  if(defined($hash->{CD})) { # Clients
    close($hash->{CD});
    delete($hash->{CD}); 
    delete($selectlist{$name});
    delete($hash->{FD});  # Avoid Read->Close->Write
    delete $attr{$name} if($dodel);
    delete $defs{$name} if($dodel);
  }
  
  if(defined($hash->{SERVERSOCKET})) {          # Server
    close($hash->{SERVERSOCKET});
    $name = $name . "." . $hash->{PORT};
    delete($selectlist{$name});
    delete($hash->{FD});  # Avoid Read->Close->Write
  }
    
  return undef;
}

#**************************************************************
###############################################################
#                  TcpCommunicationThread
###############################################################
#**************************************************************
sub TcpCommunicationThread
{
  my $hash = shift;
  my $name = $hash->{NAME};
  
  my $nhash = TcpServerAccept($hash, "WOLF_ISM8I");
  my $client_socket = $nhash->{CD};
  return "Client socked creation failed." if(!$client_socket);

  $client_socket->autoflush(1);
  my $csname = $client_socket->peerhost().":".$client_socket->peerport();

  Log3 $name, 4, "$name: Connected to $csname";
  enqueReadings("state", "Connected");

  my ($data, $ret_read, @fields, $forewardsocket, $answ, @answers, $ret_write, $r, $f_recbuf, $msg);
  my ($deq, @deqfields, $qcommand, $qvalue);
  my $showDebug = AttrVal($name, "showDebugData", 0);
  my $forewardAddress = AttrVal($name, "forewardAddress", "none");
  my $starter = chr(0x06).chr(0x20).chr(0xf0).chr(0x80);
  $hash->{DeviceName} = "";
	
  #Einmalig alle Werte vom ISM8i anfordern (06 20 F0 80 00 16 04 00 00 00 F0 D0):
  my $getAll = chr(0x06).chr(0x20).chr(0xf0).chr(0x80).chr(0x00).chr(0x16).chr(0x04).chr(0x00).chr(0x00).chr(0x00).chr(0xf0).chr(0xd0);
  syswrite($client_socket, $getAll);
  
  while(1) {	
    $ret_read = sysread($client_socket, $data, 50000); # <<<=== HIER WERDEN DIE DATAGRAMME GELESEN !!!
	
	#Telegramm beantworten und weiterverarbeiten:
    if (defined($ret_read) and defined($data) and length($data) > 0) {
       Log3 $name, 5, "$name: data read -------> ".dataToHex($data);
       
	   @answers = @{ create_answer($name, $data) };
	   
	   while (scalar(@answers) > 0) {
	      $answ = shift(@answers);
		  
          if ( length($answ) > 0 ) { 
	         $ret_write = syswrite($client_socket, $answ);  # <<<=== HIER WERDEN DIE DATAGRAMME QUITTIERT !!!
		  
             if ($showDebug) {
                enqueReadings("_DBG_SENT_BYTES", $ret_write);
                enqueReadings("_DBG_SENT_DATA", dataToHex($answ));
		     }
		  }
	   }

       eval { decodeThreadTelegram($name, $data); }; # <<<=== HIER WERDEN DIE DATAGRAMME AUSGEWERTET !!! 'eval' für Fehler abfangen
	 }	

    if ($showDebug) {
       enqueReadings("_DBG_SOCKET", $client_socket);
       enqueReadings("_DBG_CLIENT_ADDRESS", $csname);
       enqueReadings("_DBG_RECEIVED_BYTES", $ret_read);
       enqueReadings("_DBG_RECEIVED_DATA", dataToHex($data));
    }
		 
	#Falls Forewardadresse festgelegt, dann Daten weiterschicken:
    if ( $forewardAddress ne "none" ) {
       my $fwhash = $hash;			 
	   $fwhash->{DeviceName} = $forewardAddress; 
	   my $err = DevIo_OpenDev($fwhash, undef,  undef, undef);
			
	   if (defined($err)) { 
          Log3 $name, 3, "$name: Foreward error: $err";
       } else {
	      my $epoc = time();
	      do { } until (DevIo_IsOpen($fwhash) or (time() - $epoc >= 2)); # Wartet auf offene Verbindung oder bricht nach 2 Sekunden ab.
	      if (DevIo_IsOpen($fwhash)) {
             Log3 $name, 5, "$name: Foreward IO-Objekt: ". DevIo_IsOpen($fwhash);
	         DevIo_SimpleWrite($fwhash, $data, 0); 
	         DevIo_CloseDev($fwhash);
	      }
	   }
    } 

    #Daten aus dem Haupt-Thread verarbeiten:
    while ($sendToThreadQueue->pending() > 0) {
        $deq = $sendToThreadQueue->dequeue_nb();
        if (!defined($deq)) { $deq = " $qSplitter $qSplitter "; }
        @deqfields = split(/$qSplitter/, $deq);
	 
	    if (scalar(@deqfields) == 2) { 
	       $qcommand = $deqfields[0];
		   $qvalue = $deqfields[1]; 
	       if ($qcommand eq "showDebug") { $showDebug = $qvalue; }
	       if ($qcommand eq "forewardAddress") { $forewardAddress = $qvalue; }
	       if ($qcommand eq "sendDatagramm") { 
		      syswrite($client_socket, $qvalue); 
			  Log3 ($name, 5, "Datagramm transmited: ".dataToHex($qvalue));
              if ($showDebug) { enqueReadings("_DBG_DEND_DATAGRAMM_DATA", dataToHex($qvalue)); }
		   }
	    } 
    } 
  }

  shutdown($client_socket, 2);
  $client_socket->close(); 
  delete($selectlist{$nhash->{NAME}});
  delete($nhash->{FD});
  
  enqueReadings("state", "Diconnected");

	
  # Client has exited so thread should exit too
  threads->exit();
  return;
}


#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~


###############################################################
#                  TimerStartOrUpdate
###############################################################
#Startet oder updatet den InternalTimer 
###############################################################
sub TimerStartOrUpdate($) 
{
  my ($hash) = @_;
  my $name = $hash->{NAME};
  my $tout = 1; # Sekunden für den Timeout
  
  RemoveInternalTimer($hash);
  InternalTimer(gettimeofday() + $tout, "WOLF_ISM8I_TimeoutFunction", $hash);
}


###############################################################
#                  TimerKill
###############################################################
#Löscht den InternalTimer 
###############################################################
sub TimerKill($) 
{
  my ($hash) = @_;
  RemoveInternalTimer($hash);
}


###############################################################
#                  getUniq
###############################################################
sub splitTelegrams($)
{
   my $data = shift;
   my $splitter = chr(0x06).chr(0x20).chr(0xf0).chr(0x80);
   my @oldfields = split(/$splitter/, $data);
   my (@newfields, %hash, @unique);
   
   foreach my $t (@oldfields) { 
      if ($t ne $splitter and length($t) > 0) { push(@newfields, $splitter.$t); } 
   }
   
   %hash = map { $_ => 1 } @newfields;
   @unique = keys %hash;

   return \@unique;	
}	   


###############################################################
#                  create_answer
###############################################################
#Erzeugt ein SetDatapointValue.Res Telegramm das an das ISM8i 
#zurückgeschickt wird.
###############################################################
sub create_answer($@)
{
   my ($name, $data) = @_;
 
   return "" if (length($data) <=0);
   
   my @datafields = @{ splitTelegrams($data) };
   my ($telegram, @h, @a, $answer, @answers);
   
   while (scalar(@datafields) > 0) {
      $telegram = shift(@datafields);
      if (length($telegram) >= 14) {
         @h = unpack("H2" x length($telegram), $telegram);
         if ($h[10] eq "f0" and $h[11] eq "06") {
            @a = ($h[0],$h[1],$h[2],$h[3],"00","11",$h[6],$h[7],$h[8],$h[9],$h[10],"86",$h[12],$h[13],"00","00","00");
		   	$answer = pack("H2" x 17, @a);
			push(@answers, $answer);
   
            Log3 $name, 5, "$name: created answer -->  ".dataToHex($answer);
         }
      }
   }
   
   return \@answers;
}


###############################################################
#                  decodeThreadTelegram
###############################################################
#Telegramme entschlüsseln und die entsprechenden Werte zur 
#weiteren Entschlüsselung weiterreichen an sub getCsvResult
###############################################################
sub decodeThreadTelegram($@)
{
   #my ($name, $telegram) = @_;
   my ($name, $data) = @_;

   return if (length($data) <=0);

   my @datafields = @{ splitTelegrams($data) };
   my ($telegram, @h, $FrameSize, $MainService, $SubService, $StartDatapoint, $NumberOfDatapoints, $Position, $ignores, @ignore_dp, %ign_params);
   my ($n, $DP_ID, $DP_command, $DP_length, $v, $reading, $wert, $i, $DP_value, $auswertung, $last_auswertung, @fields, $ts, $rc); 

   while (scalar(@datafields) > 0) {
      $telegram = shift(@datafields);
      my @h = unpack("H2" x length($telegram), $telegram);
      my $hex_result = join(" ", @h);

      Log3 $name, 5, "$name: decode telegram ->   $hex_result";
 
      $FrameSize = hex($h[4].$h[5]);
      $MainService = hex($h[10]);
      $SubService = hex($h[11]);
   
      if ($FrameSize != length($telegram)) {
         Log3 $name, 4, "$name: decodeTelegram ERROR: TelegrammLength/FrameSize missmatch. [".$FrameSize."/".length($telegram)."]";
      } elsif ($SubService != 0x06) {
         Log3 $name, 4, "$name: decodeTelegram WARNING: No SetDatapointValue.Req. [".sprintf("%x", $SubService)."]";
      } elsif ($MainService == 0xF0 and $SubService == 0x06) {
         $StartDatapoint = hex($h[12].$h[13]);
         $NumberOfDatapoints = hex($h[14].$h[15]);
	     $Position = 0;
	     $ignores = AttrVal($name, "ignoreDatapoints", "1000 1001 1002");
         @ignore_dp = split(/ /, $ignores);
         %ign_params = map { $_ => 1 } @ignore_dp;

	     for ($n=1; $n <= $NumberOfDatapoints; $n++) {
            $DP_ID = hex($h[$Position + 16].$h[$Position + 17]);
            $DP_command = hex($h[$Position + 18]);
            $DP_length = hex($h[$Position + 19]);
            $v = "";
            $reading = "";
            $last_auswertung = "";
		 
            for ($i=0; $i <= $DP_length - 1; $i++) { $v .= $h[$Position + 20 + $i]; }
            $DP_value = hex($v);
	        $auswertung = time.";".getCsvResult($DP_ID, $DP_value);

		    if ($auswertung ne $last_auswertung) {
		   	   $last_auswertung = $auswertung;
			 
			   @fields = split(/;/, $auswertung); # DP_ID [1]; Gerät [2]; Erignis [3]; Out/In [4]; Wert [5]; Einheit [6] (falls vorhanden)
     
			   if (!exists($ign_params{$fields[1]})) {  # <- ignoreDatapoints beachten
			      # Auswertung für FHEM erstellen 
	              $reading = getFhemFriendly($fields[2]).".".$fields[1].".".$fields[4].".".getFhemFriendly($fields[3]); # Geraet . DP ID . Out/In . Datenpunkt
			      if (scalar(@fields) == 7) { $reading .= ".".getFhemFriendly($fields[6]); } # Einheit (wenn vorhanden)
			      $wert = $fields[5]; # Wert (nach Leerstelle!)
			
			      # !!! Hier wird das decodierte Telegramm mit Wert hinzugefügt:
                  enqueReadings($reading, $wert);
			      Log3 $name, 5, "$name: telegram result ->    $reading = $wert";
               } else {
			      Log3 $name, 5, "$name: telegram id $fields[1] ignored -> $reading = $wert";
               }
		    }
		    $Position += 4 + $DP_length;
	     }
      }
   }
}


###############################################################
#                  enqueReadings
###############################################################
#Fügt Reading und Wert einer Queue zu die dann Timer-gesteuert 
#ausgegeben wird. Dient dazu um die Daten aus den Server Thread
#in den FHEM Thread zu bekommen.
###############################################################
sub enqueReadings($$)
{
  my ($reading, $value) = @_;
  return if (!defined($reading) and !defined($value));

  if (!defined($reading)) { $reading = "_UNDEFINED"; }
  if (!defined($value)) { $value = "UNDEFINED"; }

  $dataQueue->enqueue(join($qSplitter, $reading, $value));
}


###############################################################
#                  sendToThread
###############################################################
#Sendet Daten an den Server-Thread. 
#Möglichkeiten:
#   command = 'sendDatagramm' -> value = ferig vorbereitetes Datagramm zum Senden an das ISM8i Modul
#   command = 'showDebug' -> value = 'Inhalt der Attributs showDebug'
#   command = 'forewardAddress' -> value = 'Inhalt der Attributs forewardAddress'
###############################################################
sub sendToThread($$)
{
  my ($command, $value) = @_;
  $sendToThreadQueue->enqueue(join($qSplitter, $command, $value));
}


###############################################################
#                  countWolfReadings
###############################################################
#Zählt alle ISM8i Readings. Debug und Status werden nicht 
#berücksichtigt.
###############################################################
sub countWolfReadings($)
{
  my $hash = shift;
  my $c = 0;
  my $r;
	
  if ( +(keys %{$hash->{READINGS}}) > 0 ) {
     foreach $r ( keys %{$hash->{READINGS}} ) {
       if ( ($r !~ m/^_/) and ($r ne "state") ) { $c ++ } 
     }
  }
	
  return $c;
}


###############################################################
#                  deleteIgnores
###############################################################
sub deleteIgnores($)
{
   my $hash = shift;
   my $name = $hash->{NAME};
   my $ignores = AttrVal($name, "ignoreDatapoints", "");
   my @datapoints = split(/ /, $ignores);

   foreach my $dp (@datapoints) { 
      my $reading = find_reading_on_dp($hash, $dp);
      if ( defined($reading) ) { fhem("deletereading $name $reading");; }
   }
}


###############################################################
#                  loadDatenpunkte
###############################################################
#Datenpunkte aus einem CSV File (Semikolon-separiert) laden.
#Die Reihenfolge der CSV Spalten lautet: ID; Gerät; Datenpunkt; 
#KNX-Datenpunkttyp; Output/Input; Einheit
#Die einzelnen CSV Felder dürfen keine Kommas, Leerstellen oder 
#Anführungszeichen enthalten.
###############################################################
sub loadDatenpunkte
{
   #erstmal vorsichtshalber datenpunkte array löschen:
   while(@datenpunkte) { shift(@datenpunkte); }
   
   my $file = "./FHEM/wolf_datenpunkte_15.csv";
   my $data;
   my $c = 0;
   open($data, '<:encoding(UTF-8)', $file) or die "Could not open '$file' $!\n";
   
   while (my $line = <$data>) {
     my @fields = split(/;/, r_trim($line));
	 if (scalar(@fields) == 6) {
	    $datenpunkte[0 + $fields[0]] = [ @fields ]; # <-so hinzufügen, damit der Index mit der DP ID übereinstimmt zu einfacheren Suche.
		$c ++;
	 }
   }
  
  close $data;
  Log3 undef, 4, "WOLF_ISM8I: loadDatenpunkte -> $c";

}


###############################################################
#                  loadSetter
###############################################################
#Datenpunkte aus einem CSV File (Semikolon-separiert) laden.
#Die Reihenfolge der CSV Spalten lautet: 
#0 = DP ID, 1 = Gerät, 2 = Datenpunkt, 3 = Einheit,
#4 = Wertebereich, 5 = Schrittweite 
#Die einzelnen CSV Felder dürfen keine #, Kommas, Leerstellen 
#oder Anführungszeichen enthalten.
###############################################################
sub loadSetter
{
   #erstmal vorsichtshalber writepunkte array löschen:
   while(@writepunkte) { shift(@writepunkte); }
   
   my $file = "./FHEM/wolf_writepunkte_15.csv";
   my ($data, $line, @fields, $setter, $dpid, $geraet, $datenpunkt, $einheit, $widget);
   my $c = 0;

   open($data, '<:encoding(UTF-8)', $file) or die "Could not open '$file' $!\n";
   
   while ($line = <$data>) {
	 if ($line !~ /#/) {
        @fields = split(/;/, r_trim($line));
	    if (scalar(@fields) == 6) {
		   $c ++;
	       $writepunkte[0 + $fields[0]] = [ @fields ]; # <-so hinzufügen, damit der Index mit der DP ID übereinstimmt zu einfacheren Suche.
	       $dpid = $fields[0];
	       $geraet = getFhemFriendly($fields[1]);
	       $datenpunkt = getFhemFriendly($fields[2]);
	       $einheit = getFhemFriendly($fields[3]);
           $setter = "$geraet.$dpid.$datenpunkt";
		   if (length($einheit) > 0) { $setter .= ".$einheit"; }
		   $widget = getSetterWidget($fields[4], $fields[5]);
		   if (length($widget) > 0) { $setter .= ":$widget"; }

	       $sets{$setter}="noArg"; # %sets ist die global definierte Setter Variable
		   
	       #Log3 undef, 3, "WOLF_ISM8I: loadSetter -> $setter"; 
		}
	 }
   }
	
   close $data;
   Log3 undef, 4, "WOLF_ISM8I: loadSetter -> $c";
}


###############################################################
#                  getSetterWidget
###############################################################
sub getSetterWidget($$)
{
	my $b = shift;
	my $s = shift;
	
	if ($b eq "0-1" && $s eq "1") {
		return "uzsuSelectRadio,0,1";
	} 
	elsif ($b eq "20-80" && $s eq "1") {
		return "selectnumbers,20,1,80,0,lin";
	} 
	elsif ($b eq "0-3" && $s eq "1") {
		return "uzsuSelectRadio,0,1,2,3";
	} 
	elsif ($b eq "0/2/4" && $s eq "-") {
		return "uzsuSelectRadio,0,2,4";
	} 
	elsif ($b eq "0/1/3" && $s eq "-") {
		return "uzsuSelectRadio,0,1,3";
	} 
	elsif ($b eq "m4-4" && $s eq "0.5") {
		return "selectnumbers,-4,0.5,4,1,lin";
	} 
	elsif ($b eq "0-10" && $s eq "0.5") {
		return "selectnumbers,0,0.5,10,1,lin";
	} 
	elsif ($b eq "-" && $s eq "Tag") {
		return "select,-,Montag,Dienstag,Mittwoch,Donnerstag,Freitag,Samstag,Sonntag";
	} 
	elsif ($b eq "-" && $s eq "Minute") {
		return "time";
	} 
	elsif ($b eq "0-100" && $s eq "1") {
		return "selectnumbers,0,1,100,0,lin";
	} else {
		return "";
	}
}	


###############################################################
#                  dataToHex
###############################################################
#Wandelt Daten in HEX Werte zur besseren Darstellung von 
#unleserlichen Werten.
###############################################################
sub dataToHex($)
{
   my $data = shift;
   return "" if (length($data) <= 0);
   my @h = unpack("H2" x length($data), $data);
   return join(" ", @h);
}


###############################################################
# this sub converts a decimal IP to a dotted IP
sub dec2ip($) { join '.', unpack 'C4', pack 'N', shift; }

###############################################################
# this sub converts a dotted IP to a decimal IP
sub ip2dec($) { unpack N => pack CCCC => split /\./ => shift; }

###############################################################
### Whitespace (v.a. CR LF) rechts im String löschen

sub r_trim { my $s = shift; $s =~ s/\s+$//; return $s; }

###############################################################
### Whitespace links im String löschen

sub l_trim { my $s = shift; $s =~ s/^\s+//; return $s; }

###############################################################
### Allen Whitespace im String löschen

sub all_trim { my $s = shift; $s =~ s/\s+//g; return $s; }

###############################################################
### Doppelten Whitespace im String durch ein Leezeichen ersetzen

sub dbl_trim { my $s = shift; $s =~ s/\s+/ /g; return $s; }

###############################################################
### r_trim, l_trim, dbl_trim zusammen auf einen String anwenden

sub l_r_dbl_trim { my $s = shift; my $r = l_trim(r_trim(dbl_trim($s))); return $r; }


###############################################################
#                  find_reading_on_dp
###############################################################
### Schreibt alle vorhandenen Readings ins Log
###############################################################
sub find_reading_on_dp($$) 
{
  my ($hash, $find) = @_;
  if ($find !~ m/^\d{1,3}$/) { return undef; }
  
  my $regx = "^.*\\.$find\\..*"; # /^.*\.\d{1,3}\..*/
  my $r;
  
  foreach $r ( keys %{ $hash->{READINGS} } ) { 
    if ($r =~ m/$regx/) { return $r; }
  }
  
  return undef;  
}


###############################################################
#                  getFhemFriendly
###############################################################
#Ersetzt alle Zeichen so, dass das Ergebnis als FHEM Reading 
#Name taugt.
###############################################################
sub getFhemFriendly($)
{
   my $working_string = shift;
   my @tbr = ("-","","ö","oe","ä","ae","ü","ue","Ö","Oe","Ä","Ae","Ü","Ue","ß","ss","³","3","²","2","°C","C","%","proz","[[:punct:][:space:][:cntrl:]]","_","___","_","__","_","^_","","_\$","");
   my ($i, $f, $r);
   
   if (defined($working_string)) {
      for ($i=0; $i <= scalar(@tbr)-1; $i+=2) {
         $f = $tbr[$i];
         if ($working_string =~ /$f/) {
            $r = $tbr[$i+1];
	        $working_string =~ s/$f/$r/g;
	     }
      }
      return $working_string;
   } else {
	  return "";
   }
}


###############################################################
#                  getFhemInOut
###############################################################
#Verwandelt die Out/In Angabe (ob ein Datenpunkt auch Eingaben 
#akzeptiert) in das FHEM freundlichen IO, I oder O.
###############################################################
sub getFhemInOut($)
{
  my $working_string = shift;
  my $result = "";

  if ($working_string =~ /In/) { $result .= "I"; }
  if ($working_string =~ /Out/) { $result .= "O"; }

return $result;
}


###############################################################
#                  getDatenpunkt
###############################################################
#Returnt aus dem 2D Array mit Datenpunkten den Datenpunkt als 
#Array mit der übergebenen DP ID.
#$0 = DP ID / $1 = Index des Feldes -> (0 = DP ID, 1 = Gerät, 
#2 = Datenpunkt, 3 = KNX-Datenpunkttyp, 4 = Output/Input, 
#5 = Einheit)
###############################################################
sub getDatenpunkt($$)
{
   my ($dpid, $index) = @_;
   my $d = $datenpunkte[$dpid][$index];
   if ( (defined $d) and (length($d)>0) ) { return $d; } else { return "ERROR:NotFound"; } 
}


###############################################################
#                  getCsvResult
###############################################################
#Berchnet den Inhalt des Telegrams und gibt das Ergebnis im 
#CSV Mode ';'-separiert.
#$0 = DP ID / $1 = DP Value
#Ergebnis: DP_ID [1]; Gerät [2]; Datenpunkt [3]; Out/In [4]; 
#Wert [5]; Einheit [6] (falls vorhanden)
###############################################################
sub getCsvResult($$)
{
   my ($dp_id, $dp_val) = @_;
   my $geraet = getDatenpunkt($dp_id, 1);
   my $datenpunkt = getDatenpunkt($dp_id, 2);
   my $datatype = getDatenpunkt($dp_id, 3);
   my $inout = getFhemInOut(getDatenpunkt($dp_id, 4));
   my $result = $dp_id.";".$geraet.";".$datenpunkt.";".$inout.";";
   my $v = "ERR:NoResult";
   
   if ($datatype eq "DPT_Switch") 
     {
	  if ($dp_val == 0) {$v = "Aus";} elsif ($dp_val == 1) {$v = "An";}
	  $result .= $v;
	 }
   elsif ($datatype eq "DPT_Bool") 
     {
	  if ($dp_val == 0) {$v = "Falsch";} elsif ($dp_val == 1) {$v = "Wahr";}
	  $result .= $v;
	 }
   elsif ($datatype eq "DPT_Enable") 
     {
	  if ($dp_val == 0) {$v = "Deaktiviert";} elsif ($dp_val == 1) {$v = "Aktiviert";}
	  $result .= $v;
	 }
   elsif ($datatype eq "DPT_OpenClose") 
     {
	  if ($dp_val == 0) {$v = "Offen";} elsif ($dp_val == 1) {$v = "Geschlossen";}
	  $result .= $v;
	 }
   elsif ($datatype eq "DPT_Scaling") 
     {
	  $result .= convert_DptScalingToNumber($dp_val).";%"; 
	 }
   elsif ($datatype eq "DPT_Value_Temp") 
     {
	  $result .= sprintf("%.1f", convert_DptFloatToNumber($dp_val)).";°C";
	 }
   elsif ($datatype eq "DPT_Value_Tempd") 
     {
	  $result .= sprintf("%.1f", convert_DptFloatToNumber($dp_val)).";K";
	 }
   elsif ($datatype eq "DPT_Value_Pres") 
     {
	  $result .= convert_DptFloatToNumber($dp_val).";Pa";
	 }
   elsif ($datatype eq "DPT_Power") 
     {
	  $result .= convert_DptFloatToNumber($dp_val).";kW";
	 }
   elsif ($datatype eq "DPT_Value_Volume_Flow") 
     {
	  $result .= convert_DptFloatToNumber($dp_val).";l/h";
	 }
   elsif ($datatype eq "DPT_TimeOfDay") 
     {
	  $result .= convert_DptTimeToString($dp_val);
	 }
   elsif ($datatype eq "DPT_Date") 
     {
	  $result .= convert_DptDateToString($dp_val);
	 }
   elsif ($datatype eq "DPT_FlowRate_m3/h") 
     {
	  $result .= (convert_DptLongToNumber($dp_val) * 0.0001).";m³/h";
	 }
   elsif ($datatype eq "DPT_ActiveEnergy") 
     {
	  $result .= convert_DptLongToNumber($dp_val).";Wh";
	 }
   elsif ($datatype eq "DPT_ActiveEnergy_kWh") 
     {
	  $result .= convert_DptLongToNumber($dp_val).";kWh";
	 }
   elsif ($datatype eq "DPT_HVACMode") 
     {
	  my @Heizkreis = ("Automatikbetrieb","Heizbetrieb","Standby","Sparbetrieb","-");

	  my @CWL = ("Automatikbetrieb","Nennlüftung","-","Reduzierung Lüftung","-");
	 
      if ($geraet =~ /Heizkreis/ or $geraet =~ /Mischerkreis/)
	   	{ $v = $Heizkreis[$dp_val]; }
	  elsif ($geraet =~ /CWL/)
	   	{ $v = $CWL[$dp_val]; }
      
	  if (defined $v) { $result .= $v; } else { $result .= "ERR:NoResult[".$dp_id."/".$dp_val."]";}
	 }
   elsif ($datatype eq "DPT_DHWMode") 
     {
	  my @Warmwasser = ("Automatikbetrieb","-","Dauerbetrieb","-","Standby");

      if ($geraet =~ /Warmwasser/) { $v = $Warmwasser[$dp_val]; }

	  if (defined $v) { $result .= $v; } else { $result .= "ERR:NoResult[".$dp_id."/".$dp_val."]";}
	 }
   elsif ($datatype eq "DPT_HVACContrMode") 
     {
	  my @CGB2_MGK2_TOB = ("Schornsteinferger","Heiz- Warmwasserbetrieb","-","-","-","-","Standby","Test","-","-","-","Frostschutz","-","-","-","Kalibration");

      my @BWL1S = ("Antilegionellenfunktion","Heiz- Warmwasserbetrieb","Vorwärmung","Aktive Kühlung","-","-","Standby","Test","-","-","-","Frostschutz","-","-","-","-");
				   
	  if ($geraet =~ /CGB-2/ or $geraet =~ /MGK-2/ or $geraet =~ /TOB/)
	    { $v = $CGB2_MGK2_TOB[$dp_val]; }
	  elsif ($geraet =~ /BWL-1-S/)
	   	{ $v = $BWL1S[$dp_val]; }

	  if (defined $v) { $result .= $v; } else { $result .= "ERR:NoResult[".$dp_id."/".$dp_val."]";}
	 }
	else
	 {
	  $result .= "ERR:TypeNotFound[".$datatype."]";
	 }

   return $result;   
}


###############################################################
#                  codeSetting
###############################################################
#Erzeugt ein Datagramm dass an ISM8i gesendet wird nach einem 'set'
###############################################################
sub codeSetting($$)
{
   my ($id, $value) = @_;
   my $type = getDatenpunkt($id, 3);
   my $dpv = codeValueByType($type, $value); # DP Value
   
   if (defined($dpv)) {
      my $dp = convert_NumberToChars($id, 2); # DP Id
      my $dpvLength = convert_NumberToChars(length($dpv), 1);
      my $ipHeader = chr(0x06).chr(0x20).chr(0xf0).chr(0x80);
      my $conHeader = chr(0x04).chr(0x00).chr(0x00).chr(0x00);
      my $objMsg = chr(0xf0).chr(0xc1).$dp.chr(0x00).chr(0x01).$dp.chr(0x00).$dpvLength.$dpv;
      my $frameSize = convert_NumberToChars(2 + length($ipHeader) + length($conHeader) + length($objMsg), 2);
	  
      #Debug("ISM8i codeSetting: id->$id / value->$value / type->$type / dpv->".dataToHex($dpv)." / dpvLength->".dataToHex($dpvLength));
   
	  $ipHeader = $ipHeader.$frameSize;
      return $ipHeader.$conHeader.$objMsg;
   } else {
	  return "";
   }
}


###############################################################
#                  codeValueByType
###############################################################
#Erzeugt ein Datagramm-Wert zum Senden an das ISM8i nach einem 'set'
###############################################################
sub codeValueByType($$)
{
   my ($type, $val) = @_;
   my $ret = undef;
   
   if ($type eq "DPT_Switch") {
	  if ($val == 0 or $val == 1) { $ret = convert_NumberToChars($val & 0xff, 1); }
   }
   elsif ($type eq "DPT_Value_Temp" or $type eq "DPT_Value_Tempd") {
      $ret = convert_NumberToChars(convert_NumberToDptFloat($val), 2);
   }
   elsif ($type eq "DPT_HVACMode" or $type eq "DPT_DHWMode") {
	  if ($val >= 0 and $val <= 4) { $ret = convert_NumberToChars($val & 0xff, 1); }
   }
   elsif ($type eq "DPT_Date") {
      $ret = convert_NumberToChars(convert_StringToDptTime_DayOnly($val), 3);
   }
   elsif ($type eq "DPT_TimeOfDay") {
      $ret = convert_NumberToChars(convert_StringToDptTime_TimeOnly($val), 3);
   }
   elsif ($type eq "DPT_Scaling") {
      $ret = convert_NumberToChars(convert_NumberToDptScaling($val), 1);
   }
   
   return $ret;
}	


###############################################################
#                  convert_NumberToChars
###############################################################
#Hilsfunktion für 'codeValueByType'. Maximal 4 Byte lang! 
###############################################################
sub convert_NumberToChars($$)
{
   my ($val,$len) = @_;
   my $res;
   
   if ($len == 1) {
	  $res = pack("C", getByteweise($val, 0));
   } elsif ($len == 2) {
	  $res = pack("C*", getByteweise($val, 1), getByteweise($val, 0));
   } elsif ($len == 3) {
	  $res = pack("C*", getByteweise($val, 2), getByteweise($val, 1), getByteweise($val, 0));
   } elsif ($len == 4) {
	  $res = pack("C*", getByteweise($val, 3), getByteweise($val, 2), getByteweise($val, 1), getByteweise($val, 0));
   }
   
   return $res;
}

###############################################################
#                  getLen
###############################################################
# Bestimmt die Bytelänge einer Zahl an Hand ihres Wertes.
###############################################################
sub getLen($)
{
   my $val = shift;
   my $len = 0;
  
   if ($val < 2**8) {
      $len = 1; 
   } elsif ($val >= 2**8 and $val < 2**16) {
      $len = 2; 
   } elsif ($val >= 2**16 and $val < 2**24) {
      $len = 3; 
   } elsif ($val >= 2**24) {
      $len = 4; 
   } 
   
   return $len;
}	
   

###############################################################
# 2-Octet Float Value
###############################################################
# Format: 
#   2 octets: F16
#   octet nr: 2MSB 1LSB
#   field names: FloatValue
#   encoding: MEEEEMMMMMMMMMMM
# Encoding: 
#   Float Value = (0,01*M)*2**(E)
#   E = [0...15]
#   M = [-2048...2047], two‘s complement notation
#   For all Datapoint Types 9.xxx, the encoded value 7FFFh shall always be used to denote invalid data.
# Range: [-671088,64...670760,96]
# PDT: PDT_KNX_FLOAT
###############################################################

###############################################################
#                  convert_DptFloatToNumber
###############################################################
sub convert_DptFloatToNumber($)
{
  use bignum;
  
  my $val = shift;
   
   if ($val == 0x7fff) { return "invalid"; }
   
   my $mantisse = $val & 0x07ff;
   my $exponent = ($val & 0x7800) >> 11;
   if ($val & 0x8000) { $mantisse = ~$mantisse; } # negative number in two complement
   
   return ($mantisse * 0.01) * (2 ** $exponent);
}

###############################################################
#                  convert_NumberToDptFloat
###############################################################
sub convert_NumberToDptFloat($)
{
   my $val = shift;
   
   return 0x7fff if ($val <= -671088.64 or $val >= 670760.96);
   
   $val = ($val * 100);
   my $sign = 0;
   my $exponent = 0;
   my $mantisse = 0;

   if ($val < 0) {
      $sign = 1;
      $mantisse = ~$val;
   } else {
      $mantisse = $val;
   }

   while ($mantisse > 2047) {
     $mantisse = $mantisse / 2;
     $exponent ++;
   }

   return ($sign << 15) | ($exponent << 11) | $mantisse;
}


###############################################################
#                  convert_DptLongToNumber
###############################################################
# Format: 4 octets: V32
# octet nr: 4MSB 3 2 1LSB
# field names: SignedValue
# encoding: VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV
# Encoding: Two‘s complement notation
# Range: SignedValue = [-2 147 483 648 ... 2 147 483 647]
# PDT: PDT_LONG 
###############################################################
sub convert_DptLongToNumber($)
{
   my $val = shift;
   return $val;
}


###############################################################
# DPT_Scaling
###############################################################
# Format: 8 bit: U8
# octet nr: 1
# field names: Unsigned Value
# encoding: UUUUUUUU
# Encoding: binary encoded
#           msb         lsb
#           U U U U U U U U
#           0 0 0 0 0 0 0 0 = range min./off
#           0 0 0 0 0 0 0 1 = value „low“
#           :     :       :
#           1 1 1 1 1 1 1 1 = range max.
# Range: U = [0...255]
#
# ID:   Name:       Range:    Unit: Resol.:   PDT: 
# 5.001 DPT_Scaling [0...100] %     ≈ 0,4 %   PDT_SCALING
#                                   (100/255) (alt.: PDT_UNSIGNED_CHAR)
###############################################################

###############################################################
#                  convert_DptScalingToNumber
###############################################################
sub convert_DptScalingToNumber($)
{
   my $val = shift;
   my $result = ($val & 0xff) * 100 / 255; 
   return sprintf("%.0f", $result);
}

###############################################################
#                  convert_NumberToDptScaling
###############################################################
sub convert_NumberToDptScaling($)
{
   my $val = shift;
   if ($val <= 0 or $val >= 100) { return 0x7fff; } 
   my $result = $val * 255 / 100; 
   return sprintf("%.0f", $result);
}


###############################################################
# DPT_TimeOfDay
###############################################################
# 3 Byte Time
#
# 22221111 111111 
# 32109876 54321098 76543210
# DDDHHHHH RRMMMMMM RRSSSSSS
# R Reserved
# D Weekday
# H Hour
# M Minutes
# S Seconds
# PDT: PDT_TIME
###############################################################

###############################################################
#                  convert_DptTimeToString
###############################################################
sub convert_DptTimeToString($)
{
   my $val = shift;
   
   my @weekdays = ["-","Mo","Di","Mi","Do","Fr","Sa","So"];
   my $weekday = getBitweise($val, 21, 23);
   my $hour = getBitweise($val, 16, 20);
   my $min = getBitweise($val, 8, 13);
   my $sec = getBitweise($val, 0, 5);

   return sprintf("%s %d:%d:%d", $weekdays[$weekday], $hour, $min, $sec);
}


###############################################################
#                  convert_StringToDptTime_DayOnly
###############################################################
#Übersetzt nur den Wochentag. Die Uhrzeit ist 0.
###############################################################
sub convert_StringToDptTime_DayOnly($)
{
   my $val = shift;
   my $day = substr(uc(all_trim($val)),0,2); # Ersten 2 Buchstaben des von Whitespace gereinigten und nach uppercase konvertierten Wert. 
   my @weekdays = ("-","MO","DI","MI","DO","FR","SA","SO"); # ^MO|^DI|^MI|^DO|^FR|^SA|^SO
   my $d;
   my $i = -1;
   my $c = 0;
   
   foreach $d (@weekdays) { 
      if ($d eq $day) { $i = $c; } # Index im Array
	  $c ++;
   }

   #Debug("ISM8i convert_StringToDptTime_DayOnly: val->$val / day->$day / i->$i");

   return 0x7fff if ($i == -1); # Invalide value
   
   return ($i & 0b00000111) << 21;   
}


###############################################################
#                  convert_StringToDptTime_TimeOnly
###############################################################
#Übersetzt nur die Uhrzeit. Der Wochentag ist 0.
###############################################################
sub convert_StringToDptTime_TimeOnly($)
{
   my $val = shift;
   my @date = split(/:/, $val);
   if (scalar(@date) < 2) { @date = split(/:/, "12:00:00"); }
   if (scalar(@date) == 2) { @date = split(/:/, $val.":00"); }
   my $hh = $date[0] & 0b00011111;
   my $mm = $date[1] & 0b00111111;
   my $ss = $date[2] & 0b00111111;

   return 0x7fff if ($hh < 0 or $hh > 23 or $mm < 0 or $mm > 59 or $ss < 0 or $ss > 59); # Invalide value
   
   my $ret = $ss + ($mm << 8) + ($hh << 16);
   
   return $ret;
}


###############################################################
# DPT_Date
###############################################################
# 3 byte Date
#
# 22221111 111111 
# 32109876 54321098 76543210
# RRRDDDDD RRRRMMMM RYYYYYYY
# R Reserved
# D Day
# M Month
# Y Year
###############################################################

###############################################################
#                  convert_DptDateToString
###############################################################
sub convert_DptDateToString($)
{
   my $val = shift;
   my $day = getBitweise($val, 16, 20);
   my $mon = getBitweise($val, 8, 11);
   my $year = getBitweise($val, 0, 6);
   if ($year < 90) { $year += 2000; } else { $year += 1900; }
   return sprintf("%02d.%02d.%04d", $day, $mon, $year);
}


###############################################################
#                  convert_StringToDptDate
###############################################################
sub convert_StringToDptDate($)
{
   my $val = shift;
   $val = all_trim($val);
   return 0x7fff if($val !~ m/^\d{1,2}\.\d{1,2}\.\d{4}/);
   
   my @date = split(/./, $val);
   my $day= $date[0] & 0b00011111;
   return 0x7fff if($day < 1 or $day > 31);
   my $mon = $date[1] & 0b00001111;
   return 0x7fff if($mon < 1 or $mon > 12);
   my $year = $date[2] & 0b01111111;
   return 0x7fff if($year < 2000 or $year > 2099);
   $year -= 2000;
   my $ret = $year + ($mon << 8) + ($day << 16);
   
   return $ret;
}

###############################################################
#                  getBitweise
###############################################################
#Berechnet aus einer Zahl eine Zahl anhand der vorgegebenen Bits.
#Maximal 4 Byte
#$1 = Zahl, $2 = Startbit (0-basiert), $3 = Endbit
###############################################################
sub getBitweise($$$)
{
   my ($val, $start_bit, $end_bit) = @_;
   my ($b, $result);
   my $mask = 0;
   
   for $b ($start_bit..$end_bit) {
      $mask = $mask | (2 ** $b);
   }
   $result = ($val & $mask) >> $start_bit;
   return $result;
}


###############################################################
#                  setBitwise
###############################################################
#Setzt Bits an eine entsprechende Stelle einer Zahl falls der Bits
#in der Ausgangszahl (Bit 0-basiert) vorhanden ist.
#$1 = Ausgangszahl, 
#$2 = Startbit in der neuen Zahl, 
#$3 = Endbit  in der neuen Zahl
###############################################################
sub setBitwise($$$)
{
   my ($val, $start_bit, $end_bit) = @_;
   my $newval = 0;
   my $i = 0;
   
   for ($i , $i <= ($end_bit - $start_bit), $i++) {
      if ($val & 2 ** $i) { $newval = $newval + (2 ** ($i + $start_bit)); }
   }
   
   return $newval;
}


###############################################################
#                  getByteweise
###############################################################
#Extrahiert aus einer Zahl den Byte an den geforderten Stelle.
#$0 = Zahl, $1 = Bytenummer (0-basiert, rechts anfangend)
###############################################################
sub getByteweise($$)
{
   my ($val, $byte) = @_;
   my $mask = 0xff << ($byte * 8);
   my $res = ($val & $mask) >> ($byte * 8);
   
   return $res;
}


1;

=pod
=item device
=item summary    
=item summary_DE misst und steuert Wolf Geräte.
=begin html

=end html
=begin html_DE

=end html_DE

=cut
