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
static int get(DDCTransport t, uint8_t code) {
    if (!sendPacket(t,packet(code,-1))) return -1;
    usleep(80000);
    uint8_t b[12]={};
    if (IOAVServiceReadI2C(t.service,t.chipAddress,0x51,b,sizeof(b))) return -1;
    return parse(b,sizeof(b),code);
}
static int emit(NSDictionary *d, int status) {
    NSData *data=[NSJSONSerialization dataWithJSONObject:d options:0 error:NULL];
    fwrite(data.bytes,1,data.length,stdout); fputc('\n',stdout); return status;
}
static int fail(NSString *s) { return emit(@{@"ok":@NO,@"error":s},1); }
static BOOL source(int v) { return v==15 || v==17 || v==27; }
static void selfTest(void) {
    const uint8_t expected[]={0x82,1,0x60,0xdc};
    assert([packet(0x60,-1) isEqualToData:[NSData dataWithBytes:expected length:4]]);
    const int codes[]={0x60,0xe7,0xee};
    for (int k=0;k<3;k++) {
        int code=codes[k];
        NSData *p=packet(code,0x1b11); const uint8_t *b=p.bytes;
        uint8_t c=0x6e^0x51; for(int i=0;i<p.length;i++) c^=b[i];
        assert(c==0 && b[3]==0x1b && b[4]==0x11);
        uint8_t r[]={0x6e,0x88,2,0,code,0,0,0xff,0x1b,0x11,0};
        r[10]=0x50; for(int i=0;i<10;i++) r[10]^=r[i];
        assert(parse(r,sizeof(r),code)==0x1b11 && parse(r,10,code)==-1);
        r[3]=1; assert(parse(r,sizeof(r),code)==-1); r[3]=0;
        r[9]^=1; assert(parse(r,sizeof(r),code)==-1);
    }
    assert(source(17) && !source(16));
}
int main(int argc,const char *argv[]) {
 @autoreleasepool {
    if(argc==2 && !strcmp(argv[1],"--self-test")) { selfTest(); return emit(@{@"ok":@YES},0); }
    NSString *cmd=argc>1 ? @(argv[1]) : @"";
    BOOL list=[cmd isEqual:@"list"], batch=[cmd isEqual:@"batch"];
    BOOL read=[cmd isEqual:@"get"], diag=[cmd isEqual:@"usb-read"];
    if(!(list&&argc==2) && !(batch&&argc==3) && !((read||diag)&&argc==3))
        return fail(@"用法：list | get <serial/UUID> | usb-read <serial/UUID> | batch <JSON>");
    NSArray *operations=nil;
    if(batch) {
        NSData *data=[@(argv[2]) dataUsingEncoding:NSUTF8StringEncoding];
        id obj=[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        if(![obj isKindOfClass:NSArray.class] || [obj count]<1 || [obj count]>8) return fail(@"无效的切换计划。");
        operations=obj;
        NSMutableSet *seen=[NSMutableSet set];
        for(id o in operations) {
            if(![o isKindOfClass:NSDictionary.class] || ![o[@"serial"] isKindOfClass:NSString.class] || [o[@"serial"] length]==0 || [seen containsObject:o[@"serial"]]) return fail(@"每台显示器只能有一条切换计划。");
            [seen addObject:o[@"serial"]];
            if(o[@"input"] && (![o[@"input"] isKindOfClass:NSNumber.class] || !source([o[@"input"] intValue]))) return fail(@"输入源仅支持 DP / HDMI / USB-C。");
            // USB writes require two measured association snapshots, never guessed action codes.
            if(o[@"usbMask"] || o[@"usbBits"]) {
                if(![o[@"usbMask"] isKindOfClass:NSNumber.class] || ![o[@"usbBits"] isKindOfClass:NSNumber.class] || ![o[@"usbInput"] isKindOfClass:NSNumber.class]) return fail(@"USB 校准数据不完整。");
                int mask=[o[@"usbMask"] intValue],bits=[o[@"usbBits"] intValue];
                if(mask<=0 || mask>65535 || bits<0 || bits>65535 || (bits & ~mask) || !source([o[@"usbInput"] intValue])) return fail(@"USB 校准数据无效。");
            }
            if(!o[@"input"] && !o[@"usbMask"]) return fail(@"空的切换计划。");
        }
    }
    DisplayInfos displays[MAX_DISPLAYS]={}; int count=getOnlineDisplayInfos(displays);
    NSMutableArray *items=[NSMutableArray array];
    for(int i=0;i<count;i++) if(!CGDisplayIsBuiltin(displays[i].id) && displays[i].uuid)
        [items addObject:@{@"id":displays[i].uuid,@"name":displays[i].productName?:@"外接显示器",@"serial":displays[i].alphNumSerial?:@""}];
    if(list) return emit(@{@"ok":@YES,@"displays":items},0);
    if(!batch) operations=@[@{@"serial":@(argv[2])}];
    DDCTransport transports[8]={}; NSMutableArray *results=[NSMutableArray array]; BOOL preflight=YES;
    // Open every transport before switching either screen or the USB upstream.
    for(NSUInteger j=0;j<operations.count;j++) {
        NSDictionary *o=operations[j]; NSString *identity=o[@"serial"]; int matches=0;
        for(int i=0;i<count;i++) if(!CGDisplayIsBuiltin(displays[i].id) && ([displays[i].alphNumSerial isEqual:identity] || [displays[i].uuid isEqual:identity])) { matches++; if(matches==1) transports[j]=getDisplayDDCTransport(&displays[i]); }
        NSMutableDictionary *r=[@{@"serial":identity,@"ok":@NO} mutableCopy];
        if(matches!=1 || !transports[j].service) { r[@"error"]=@"显示器不可见、序列号重复或 DDC 通道无法打开；未发送本组请求。"; preflight=NO; }
        [results addObject:r];
    }
    if(!preflight) {
        for(NSUInteger j=0;j<operations.count;j++) { if(transports[j].service) CFRelease(transports[j].service); if(!results[j][@"error"]) results[j][@"error"]=@"另一台显示器未就绪；本组未发送。"; }
        return emit(@{@"ok":@YES,@"results":results},0);
    }
    if(read || diag) {
        int input=get(transports[0],0x60); int e7=diag?get(transports[0],0xe7):-1;
        int ee=diag?get(transports[0],0xee):-1;
        CFRelease(transports[0].service);
        if(input<0) return fail(@"显示器未返回有效输入源；请检查 DDC/CI 和连接，或退出冲突的显示器工具。");
        // Dell high byte identifies the requesting host input; low byte is selected video.
        NSMutableDictionary *r=[@{@"ok":@YES,@"input":@(input&255),@"rawInput":@(input)} mutableCopy];
        if(diag) { r[@"usbValue"]=@(e7); r[@"usbInventory"]=@(ee); }
        return emit(r,0);
    }
    // Validate and read all USB plans before making any change.
    int usbValues[8]; for(int j=0;j<8;j++) usbValues[j]=-1;
    for(NSUInteger j=0;j<operations.count;j++) if(operations[j][@"usbMask"]) {
        int current=get(transports[j],0xe7); int input=get(transports[j],0x60)&255;
        int expected=[operations[j][@"usbInput"] intValue];
        int mask=[operations[j][@"usbMask"] intValue],bits=[operations[j][@"usbBits"] intValue];
        int target=(current & ~mask)|bits;
        if(current<0 || current>=0xff00 || (operations[j][@"input"] ? [operations[j][@"input"] intValue]!=expected : input!=expected) || target>=0xff00) { results[j][@"error"]=@"USB 校准与当前输入不匹配，或 E7 不支持关联映射；本组未发送。"; preflight=NO; }
        else usbValues[j]=target;
    }
    if(preflight) {
        // Video first: USB might disconnect the host. All DDC handles are already open.
        for(NSUInteger j=0;j<operations.count;j++) {
            NSDictionary *o=operations[j]; NSMutableDictionary *r=results[j];
            if(o[@"input"]) {
                BOOL sent=sendPacket(transports[j],packet(0x60,[o[@"input"] intValue]));
                r[@"videoSent"]=@(sent);
                if(!sent) r[@"error"]=@"DDC 发送失败，可能部分执行；请观察画面。";
            }
        }
        for(NSUInteger j=0;j<operations.count;j++) if(usbValues[j]>=0 && !results[j][@"error"]) {
            BOOL sent=sendPacket(transports[j],packet(0xe7,usbValues[j]));
            results[j][@"usbSent"]=@(sent);
            if(!sent) results[j][@"error"]=@"USB 请求发送失败；视频可能已切换。";
        }
        usleep(600000);
        for(NSUInteger j=0;j<operations.count;j++) {
            int value=get(transports[j],0x60);
            if(value>=0) results[j][@"input"]=@(value&255);
            results[j][@"ok"]=@(!results[j][@"error"]);
        }
    } else for(NSMutableDictionary *r in results) if(!r[@"error"]) r[@"error"]=@"USB 校验未通过；本组未发送。";
    for(NSUInteger j=0;j<operations.count;j++) CFRelease(transports[j].service);
    return emit(@{@"ok":@YES,@"results":results},0);
 }
}
