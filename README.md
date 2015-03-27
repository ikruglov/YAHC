# YAHC
YAHC - Yet another HTTP client

Features:
- minimalistic HTTP client
- managing pool of HTTP requests
- each connection is async
- each connection goes through set of states (see diagram below)
- support of various retry techincs
- user controls connections behavior

State machine and its transitions:
```
              +-----------------+            
              |   INITALIZED    <---+        
              +-----------------+   |        
                      |             |        
              +-------v---------+   |        
          +---+   RESOLVE DNS   +---+        
          |   +-----------------+   |        
          |           |             |        
          |   +-------v---------+   |        
          +---+   WAIT SYNACK   +---+        
          |   +-----------------+   |        
          |           |             |        
 Path in  |   +-------v---------+   |  Retry 
 case of  +---+    CONNECTED    +---+  logic 
 failure  |   +-----------------+   |  path  
          |           |             |        
          |   +-------v---------+   |        
          +---+     WRITING     +---+        
          |   +-----------------+   |        
          |           |             |        
          |   +-------v---------+   |        
          +---+     READING     +---+        
          |   +-----------------+   |        
          |           |             |        
          |   +-------v---------+   |        
          +--->   USER ACTION   +---+        
              +-----------------+            
                      |                      
              +-------v---------+            
              |      DONE       |            
              +-----------------+            
                                             
```

Example of usage:
```
    use YAHC::Pool;
    my @hosts = ('www.booking.com', 'www.google.com:80');
    my $pool = YAHC::Pool->new({ host => \@hosts });
    $pool->request({ path => '/', host => 'www.reddit.com' });
    $pool->request({ path => '/', host => sub { 'www.reddit.com' } });
    $pool->request({ path => '/', host => \@hosts });
    $pool->request({ path => '/' });
    $pool->request({ path => '/' });
    $pool->request({ path => '/' });
    $pool->run;
    exit 0;
```

The code is under development. Chnages to the interfaces are possible without notice.
