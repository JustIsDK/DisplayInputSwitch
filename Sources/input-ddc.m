@import Foundation;
@import IOKit;
@import CoreGraphics;
#include <assert.h>
#include "ioregistry.h"
#include "i2c.h"

static NSData *packet(uint8_t code, int value) {
    uint8_t b[6] = {value < 0 ? 0x82 : 0x84, value < 0 ? 0x01 : 0x03, code, 0, 0, 0};
    int n = value < 0 ? 4 : 6;
    if (value >= 0) { b[3] = value >> 8; b[4] = value; }
    b[n-1] = 0x6e ^ 0x51;
    for (int i=0; i<n-1; i++) b[n-1] ^= b[i];
    return [NSData dataWithBytes:b length:n];
}
static int parse(const uint8_t *b, size_t n, uint8_t code) {
    if (n < 11 || b[0]!=0x6e || b[1]!=0x88 || b[2]!=2 || b[3]!=0 || b[4]!=code) return -1;
    uint8_t c=0x50;
    for (int i=0;i<11;i++) c ^= b[i];
    return c ? -1 : ((int)b[8]<<8)|b[9];
}
static BOOL sendPacket(DDCTransport t, NSData *p) {
    usleep(50000);
    if (IOAVServiceWriteI2C(t.service,t.chipAddress,0x51,(void *)p.bytes,(uint32_t)p.length)) return NO;
    usleep(50000);
    return IOAVServiceWriteI2C(t.service,t.chipAddress,0x51,(void *)p.bytes,(uint32_t)p.length)==kIOReturnSuccess;
}
static int get(DDCTransport t, uint8_t code, int *maximum) {
    if (!sendPacket(t,packet(code,-1))) return -1;
    usleep(80000);
    uint8_t b[12]={};
    if (IOAVServiceReadI2C(t.service,t.chipAddress,0x51,b,sizeof(b))) return -1;
    int current=parse(b,sizeof(b),code);
    if (current>=0 && maximum) *maximum=((int)b[6]<<8)|b[7];
    return current;
}
static int emit(NSDictionary *d, int status) {
    NSData *data=[NSJSONSerialization dataWithJSONObject:d options:0 error:NULL];
    fwrite(data.bytes,1,data.length,stdout); fputc('\n',stdout); return status;
}
static int fail(NSString *s) { return emit(@{@"ok":@NO,@"error":s},1); }
static BOOL source(int v) { return v==15 || v==17 || v==27; }
static BOOL integer(id n, int low, int high) {
    return [n isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)n)!=CFBooleanGetTypeID() && [n doubleValue]==[n intValue] && [n intValue]>=low && [n intValue]<=high;
}
static BOOL validOperation(id o) {
    if (![o isKindOfClass:NSDictionary.class] || ![o[@"serial"] isKindOfClass:NSString.class] || [o[@"serial"] length]==0) return NO;
    for (id key in o) if (![@[@"serial",@"input",@"brightness"] containsObject:key]) return NO;
    if (!!o[@"input"] == !!o[@"brightness"]) return NO;
    return o[@"input"] ? integer(o[@"input"],0,255) && source([o[@"input"] intValue]) : integer(o[@"brightness"],0,100);
}
static int brightnessRaw(int percent, int maximum) { return (percent*maximum+50)/100; }
static void selfTest(void) {
    const uint8_t expected[]={0x82,1,0x60,0xdc};
    assert([packet(0x60,-1) isEqualToData:[NSData dataWithBytes:expected length:4]]);
    const uint8_t brightnessRead[]={0x82,1,0x10,0xac};
    assert([packet(0x10,-1) isEqualToData:[NSData dataWithBytes:brightnessRead length:4]]);
    const int codes[]={0x60,0x10};
    for (int k=0;k<2;k++) {
        int code=codes[k];
        NSData *p=packet(code,0x1b11); const uint8_t *b=p.bytes;
        uint8_t c=0x6e^0x51; for(int i=0;i<p.length;i++) c^=b[i];
        assert(c==0 && b[3]==0x1b && b[4]==0x11);
        uint8_t r[]={0x6e,0x88,2,0,code,0,0,100,0x1b,0x11,0};
        r[10]=0x50; for(int i=0;i<10;i++) r[10]^=r[i];
        assert(parse(r,sizeof(r),code)==0x1b11 && parse(r,10,code)==-1);
        assert(parse(r,sizeof(r),code^1)==-1);
        r[3]=1; assert(parse(r,sizeof(r),code)==-1); r[3]=0;
        r[9]^=1; assert(parse(r,sizeof(r),code)==-1);
    }
    assert(validOperation(@{@"serial":@"a",@"brightness":@0}));
    assert(validOperation(@{@"serial":@"a",@"brightness":@100}));
    assert(!validOperation(@{@"serial":@"a",@"brightness":@101}));
    assert(!validOperation(@{@"serial":@"a",@"brightness":@(-1)}));
    assert(!validOperation(@{@"serial":@"a",@"brightness":@1.5}));
    assert(!validOperation(@{@"serial":@"a",@"input":@15,@"brightness":@20}));
    assert(!validOperation(@{@"serial":@"a",@"input":@15,@"usbMask":@1}));
    assert(!validOperation(@{@"serial":@"a"}));
    assert(brightnessRaw(0,255)==0 && brightnessRaw(50,255)==128 && brightnessRaw(100,65535)==65535);
}
int main(int argc,const char *argv[]) {
 @autoreleasepool {
    if(argc==2 && !strcmp(argv[1],"--self-test")) { selfTest(); return emit(@{@"ok":@YES},0); }
    NSString *cmd=argc>1 ? @(argv[1]) : @"";
    BOOL list=[cmd isEqual:@"list"], batch=[cmd isEqual:@"batch"], read=[cmd isEqual:@"get"], brightness=[cmd isEqual:@"brightness-get"];
    if(!(list&&argc==2) && !(batch&&argc==3) && !((read||brightness)&&argc==3)) return fail(@"用法：list | get <serial/UUID> | brightness-get <serial/UUID> | batch <JSON>");
    NSArray *operations=nil;
    if(batch) {
        id obj=[NSJSONSerialization JSONObjectWithData:[@(argv[2]) dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
        if(![obj isKindOfClass:NSArray.class] || [obj count]<1 || [obj count]>8) return fail(@"无效的显示器控制计划。");
        operations=obj; NSMutableSet *seen=[NSMutableSet set];
        for(id o in operations) {
            if(!validOperation(o)) return fail(@"每条计划须指定 serial 及一个 input（15/17/27）或 brightness（0–100），不支持其他字段。");
            if([seen containsObject:o[@"serial"]]) return fail(@"每台显示器只能有一条控制计划。");
            [seen addObject:o[@"serial"]];
        }
    }
    DisplayInfos displays[MAX_DISPLAYS]={}; int count=getOnlineDisplayInfos(displays);
    NSMutableArray *items=[NSMutableArray array];
    for(int i=0;i<count;i++) if(!CGDisplayIsBuiltin(displays[i].id) && displays[i].uuid)
        [items addObject:@{@"id":displays[i].uuid,@"name":displays[i].productName?:@"外接显示器",@"serial":displays[i].alphNumSerial?:@""}];
    if(list) return emit(@{@"ok":@YES,@"displays":items},0);
    if(!batch) operations=@[@{@"serial":@(argv[2])}];
    DDCTransport transports[8]={}; NSMutableArray *results=[NSMutableArray array]; BOOL preflight=YES;
    // Open every target before sending any changes.
    for(NSUInteger j=0;j<operations.count;j++) {
        NSString *identity=operations[j][@"serial"]; int matches=0;
        for(int i=0;i<count;i++) if(!CGDisplayIsBuiltin(displays[i].id) && ([displays[i].alphNumSerial isEqual:identity] || [displays[i].uuid isEqual:identity])) { matches++; if(matches==1) transports[j]=getDisplayDDCTransport(&displays[i]); }
        NSMutableDictionary *r=[@{@"serial":identity,@"ok":@NO} mutableCopy];
        if(matches!=1 || !transports[j].service) { r[@"error"]=@"显示器不可见、序列号重复或 DDC 通道无法打开；未发送本组请求。"; preflight=NO; }
        [results addObject:r];
    }
    if(!batch && preflight) {
        int maximum=-1, value=get(transports[0],brightness?0x10:0x60,&maximum);
        CFRelease(transports[0].service);
        if(value<0 || (brightness && (maximum<=0 || value>maximum))) return fail(@"显示器未返回有效参数；请检查 DDC/CI、连接、HDR 设置或其他控制工具。");
        if(brightness) return emit(@{@"ok":@YES,@"brightness":@(value),@"maxBrightness":@(maximum)},0);
        // Dell high byte identifies the requesting host input; low byte is selected video.
        return emit(@{@"ok":@YES,@"input":@(value&255),@"rawInput":@(value)},0);
    }
    int targets[8]={};
    if(preflight) for(NSUInteger j=0;j<operations.count;j++) {
        if(operations[j][@"brightness"]) {
            int maximum=-1, current=get(transports[j],0x10,&maximum);
            if(current<0 || maximum<=0 || current>maximum) { results[j][@"error"]=@"无法读取有效亮度；请检查 DDC/CI、HDR 或预设模式。本组未发送。"; preflight=NO; }
            else targets[j]=brightnessRaw([operations[j][@"brightness"] intValue],maximum);
        } else targets[j]=[operations[j][@"input"] intValue];
    }
    if(preflight) {
        for(NSUInteger j=0;j<operations.count;j++) {
            BOOL isBrightness=operations[j][@"brightness"]!=nil;
            BOOL sent=sendPacket(transports[j],packet(isBrightness?0x10:0x60,targets[j]));
            results[j][isBrightness?@"brightnessSent":@"videoSent"]=@(sent);
            if(!sent) results[j][@"error"]=@"DDC 发送失败，可能部分执行；请检测后重试。";
        }
        usleep(600000);
        for(NSUInteger j=0;j<operations.count;j++) {
            BOOL isBrightness=operations[j][@"brightness"]!=nil;
            int maximum=-1, value=get(transports[j],isBrightness?0x10:0x60,&maximum);
            if(isBrightness) {
                if(value>=0 && maximum>0 && value<=maximum) {
                    results[j][@"brightness"]=@(value); results[j][@"maxBrightness"]=@(maximum);
                    if(value!=targets[j] && !results[j][@"error"]) results[j][@"error"]=@"亮度回读未达到目标；请检查 HDR、预设模式或其他控制工具。";
                } else if(!results[j][@"error"]) results[j][@"error"]=@"亮度请求已发送，但无法读取确认。";
            } else if(value>=0) results[j][@"input"]=@(value&255);
            results[j][@"ok"]=results[j][@"error"] ? @NO : @YES;
        }
    } else for(NSMutableDictionary *r in results) if(!r[@"error"]) r[@"error"]=@"另一台显示器未就绪；本组未发送。";
    for(NSUInteger j=0;j<operations.count;j++) if(transports[j].service) CFRelease(transports[j].service);
    if(!batch) return fail(@"目标显示器不可见或 DDC 通道无法打开。");
    return emit(@{@"ok":@YES,@"results":results},0);
 }
}
