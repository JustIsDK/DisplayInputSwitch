// Hardware test fixture only: put one supported monitor in Smart HDR Off to exercise cold enabling.
#define main input_ddc_main
#include "../../Sources/input-ddc.m"
#undef main
int main(int argc,const char *argv[]) { @autoreleasepool {
    if(argc!=2) return 2;
    DisplayInfos displays[MAX_DISPLAYS]={}; int count=getOnlineDisplayInfos(displays), index=-1, matches=0;
    for(int i=0;i<count;i++) if([displays[i].alphNumSerial isEqual:@(argv[1])]) { matches++; index=i; }
    if(matches!=1 || displays[index].vendor!=4268 ||
       ![@[@"DELL U2723QX",@"DELL U2723QE"] containsObject:displays[index].productName]) return 3;
    DDCTransport t=getDisplayDDCTransport(&displays[index]); if(!t.service) return 4;
    int before=get(t,0xf2,NULL);
    fprintf(stderr,"Preparing Smart HDR Off: %s, F2=%d\n",argv[1],before);
    if(before<0) { CFRelease(t.service); return 6; }
    BOOL sent=smartHDR(t,NO);
    CFRelease(t.service); return sent ? 0 : 5;
}}
