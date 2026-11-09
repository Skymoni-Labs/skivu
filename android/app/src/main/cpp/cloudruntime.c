#define _GNU_SOURCE
#include <jni.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdlib.h>
#include <stdio.h>
#include <signal.h>
#include <sys/wait.h>
#include <sys/utsname.h>

// The private PRoot process tree is the only native child owned here. Never
// enumerate/kill an Android UID: other app tasks and old migration hosts exist.
JNIEXPORT jint JNICALL Java_com_skyjjgw_independent_ski_CloudNative_start(JNIEnv *e,jobject self,
 jint in,jint out,jint err,jstring proot,jstring loader,jstring root,jstring tmp,jstring home,jstring work,jstring scripts){
 (void)self;jstring v[]={proot,loader,root,tmp,home,work,scripts};const char *s[7];for(int i=0;i<7;i++)s[i]=(*e)->GetStringUTFChars(e,v[i],0);
 char *te,*le,*hb,*wb,*sb;asprintf(&te,"PROOT_TMP_DIR=%s",s[3]);asprintf(&le,"PROOT_LOADER=%s",s[1]);asprintf(&hb,"%s:/root/skivu-home",s[4]);asprintf(&wb,"%s:/workspace",s[5]);asprintf(&sb,"%s:/opt/skivu-cloud",s[6]);
 char *argv[]={(char*)s[0],"--kill-on-exit","-0","-r",(char*)s[2],"-b","/dev","-b","/proc","-b",hb,"-b",wb,"-b",sb,"-w","/workspace","/opt/node/bin/node","/opt/skivu-cloud/executor.mjs",NULL};
 char *env[]={te,le,"PROOT_NO_SECCOMP=1","PROOT_ASSUME_NEW_SECCOMP=1","HOME=/root/skivu-home","TMPDIR=/tmp","PATH=/opt/node/bin:/usr/local/bin:/usr/bin:/bin","NODE_PATH=/opt/dsh/node_modules","ANDROID_ROOT=/system","ANDROID_DATA=/data",NULL};
 pid_t pid=fork();if(pid==0){if(setpgid(0,0)<0)_exit(124);int a=fcntl(in,F_DUPFD_CLOEXEC,10),b=fcntl(out,F_DUPFD_CLOEXEC,10),c=fcntl(err,F_DUPFD_CLOEXEC,10);if(a<0||b<0||c<0||dup2(a,0)<0||dup2(b,1)<0||dup2(c,2)<0)_exit(120);for(int i=3;i<65536;i++)close(i);execve(s[0],argv,env);_exit(122);}
 for(int i=0;i<7;i++)(*e)->ReleaseStringUTFChars(e,v[i],s[i]);free(te);free(le);free(hb);free(wb);free(sb);return pid;
}
JNIEXPORT jint JNICALL Java_com_skyjjgw_independent_ski_CloudNative_poll(JNIEnv *e,jobject o,jint pid){(void)e;(void)o;int status;pid_t r=waitpid(pid,&status,WNOHANG);return r==0?0:r==pid?(WIFEXITED(status)?WEXITSTATUS(status)+1:257):-1;}
