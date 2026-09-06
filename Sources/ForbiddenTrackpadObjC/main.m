#import <Cocoa/Cocoa.h>
#import <IOBluetooth/IOBluetooth.h>

static NSString * const AppID = @"app.forbiddentrackpad.ForbiddenTrackpad";

static NSString *NormalizeAddress(NSString *value) {
    return [[[value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString] stringByReplacingOccurrencesOfString:@":" withString:@"-"];
}

@interface Preferences : NSObject
@property(nonatomic, readonly) NSString *selectedAddress;
- (void)setSelectedAddress:(NSString *)address;
@end

@implementation Preferences {
    NSUserDefaults *_defaults;
    NSString *_selectedAddressKey;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _defaults = NSUserDefaults.standardUserDefaults;
    _selectedAddressKey = [NSString stringWithFormat:@"selectedAddress.%@", [self hostID]];
    return self;
}

- (NSString *)hostID {
    NSTask *task = [[NSTask alloc] init];
    NSPipe *pipe = [NSPipe pipe];
    task.launchPath = @"/usr/sbin/ioreg";
    task.arguments = @[@"-rd1", @"-c", @"IOPlatformExpertDevice"];
    task.standardOutput = pipe;
    task.standardError = [NSPipe pipe];
    @try {
        [task launch];
        [task waitUntilExit];
        NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
        NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        for (NSString *line in [output componentsSeparatedByString:@"\n"]) {
            if ([line containsString:@"IOPlatformUUID"]) {
                NSArray *parts = [line componentsSeparatedByString:@"\""];
                if (parts.count > 3) return parts[3];
            }
        }
    } @catch (__unused NSException *exception) {}
    return NSHost.currentHost.localizedName ?: NSHost.currentHost.name ?: @"unknown-mac";
}

- (NSString *)selectedAddress {
    NSString *value = [_defaults stringForKey:_selectedAddressKey];
    if (value.length) return value;
    NSString *legacy = [_defaults stringForKey:@"selectedAddress"];
    if (legacy.length) {
        NSString *normalized = NormalizeAddress(legacy);
        [_defaults setObject:normalized forKey:_selectedAddressKey];
        return normalized;
    }
    return @"";
}

- (void)setSelectedAddress:(NSString *)address {
    [_defaults setObject:NormalizeAddress(address ?: @"") forKey:_selectedAddressKey];
}
@end

@interface BluetoothManager : NSObject
- (NSArray<IOBluetoothDevice *> *)pairedDevices;
- (IOBluetoothDevice *)deviceForAddress:(NSString *)address;
- (void)connectAddress:(NSString *)address error:(NSError **)error;
- (void)disconnectAddress:(NSString *)address error:(NSError **)error;
- (void)forgetAddress:(NSString *)address error:(NSError **)error;
@end

@interface ConnectionWaiter : NSObject
@property(nonatomic) IOReturn result;
@property(nonatomic) dispatch_semaphore_t semaphore;
@end

@implementation ConnectionWaiter
- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _result = kIOReturnTimeout;
    _semaphore = dispatch_semaphore_create(0);
    return self;
}
- (void)connectionComplete:(IOBluetoothDevice *)device status:(IOReturn)status {
    _result = status;
    dispatch_semaphore_signal(_semaphore);
}
@end

@implementation BluetoothManager
- (NSArray<IOBluetoothDevice *> *)pairedDevices {
    NSArray *devices = [IOBluetoothDevice pairedDevices] ?: @[];
    return [devices sortedArrayUsingComparator:^NSComparisonResult(IOBluetoothDevice *a, IOBluetoothDevice *b) {
        if (a.isConnected != b.isConnected) return a.isConnected ? NSOrderedAscending : NSOrderedDescending;
        return [(a.name ?: a.addressString ?: @"") localizedCaseInsensitiveCompare:(b.name ?: b.addressString ?: @"")];
    }];
}

- (IOBluetoothDevice *)deviceForAddress:(NSString *)address {
    NSString *target = NormalizeAddress(address);
    for (IOBluetoothDevice *device in [self pairedDevices]) {
        if ([NormalizeAddress(device.addressString ?: @"") isEqualToString:target]) return device;
    }
    return [IOBluetoothDevice deviceWithAddressString:target] ?: [IOBluetoothDevice deviceWithAddressString:[target stringByReplacingOccurrencesOfString:@"-" withString:@":"]];
}

- (void)connectAddress:(NSString *)address error:(NSError **)error {
    IOBluetoothDevice *device = [self deviceForAddress:address];
    if (!device) {
        if (error) *error = [NSError errorWithDomain:AppID code:1 userInfo:@{NSLocalizedDescriptionKey: @"Selected device is not visible to Bluetooth right now. Touch the trackpad, then press Refresh."}];
        return;
    }
    if (device.isConnected) { [device addToFavorites]; return; }

    IOReturn last = kIOReturnSuccess;
    for (NSInteger attempt = 0; attempt < 2; attempt++) {
        ConnectionWaiter *waiter = [ConnectionWaiter new];
        BluetoothHCIPageTimeout timeout = (BluetoothHCIPageTimeout)BluetoothGetSlotsFromSeconds(3.0);
        IOReturn result = [device openConnection:waiter withPageTimeout:timeout authenticationRequired:NO];
        if (result != kIOReturnSuccess) {
            last = result;
        } else {
            dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.5 * NSEC_PER_SEC));
            long wait = dispatch_semaphore_wait(waiter.semaphore, deadline);
            last = wait == 0 ? waiter.result : kIOReturnTimeout;
        }

        if (last == kIOReturnSuccess || device.isConnected) { [device addToFavorites]; return; }
        if (attempt < 1 && (last == kIOReturnTimeout || last == kIOReturnBusy || last == kIOReturnOffline || last == kIOReturnNotReady)) {
            [NSThread sleepForTimeInterval:0.8];
        } else {
            break;
        }
    }

    NSString *code = [NSString stringWithFormat:@"0x%08X", (uint32_t)last];
    NSString *name = device.name ?: address.uppercaseString;
    NSString *message = last == kIOReturnTimeout
        ? [NSString stringWithFormat:@"Не дождался ответа от %@. Трекпад спит или подключен ко второму Mac. Коснись трекпада и нажми Test Connect еще раз. Код: %@.", name, code]
        : [NSString stringWithFormat:@"Не удалось подключить %@. Код: %@.", name, code];
    if (error) *error = [NSError errorWithDomain:AppID code:last userInfo:@{NSLocalizedDescriptionKey: message}];
}

- (void)disconnectAddress:(NSString *)address error:(NSError **)error {
    IOBluetoothDevice *device = [self deviceForAddress:address];
    if (!device || !device.isConnected) return;
    IOReturn result = [device closeConnection];
    if (result != kIOReturnSuccess && error) {
        *error = [NSError errorWithDomain:AppID code:result userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Could not disconnect %@. Result: %d", device.name ?: address, result]}];
    }
}

- (void)forgetAddress:(NSString *)address error:(NSError **)error {
    IOBluetoothDevice *device = [self deviceForAddress:address];
    if (!device) {
        if (error) *error = [NSError errorWithDomain:AppID code:1 userInfo:@{NSLocalizedDescriptionKey: @"Selected device is not visible to Bluetooth right now."}];
        return;
    }

    if (device.isConnected) {
        IOReturn result = [device closeConnection];
        if (result != kIOReturnSuccess && error) {
            *error = [NSError errorWithDomain:AppID code:result userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Could not disconnect %@ before forget. Result: %d", device.name ?: address, result]}];
            return;
        }
    }

    [device removeFromFavorites];
    [self performPrivateSelector:@"removeLinkKey" onDevice:device];
    [self performPrivateSelector:@"remove" onDevice:device];
    [self performPrivateSelector:@"forceRemove" onDevice:device];
}

- (void)performPrivateSelector:(NSString *)name onDevice:(IOBluetoothDevice *)device {
    SEL selector = NSSelectorFromString(name);
    if ([device respondsToSelector:selector]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [device performSelector:selector];
#pragma clang diagnostic pop
    }
}
@end

@interface LaunchAgentManager : NSObject
@property(nonatomic, readonly) BOOL installed;
- (void)setInstalled:(BOOL)enabled error:(NSError **)error;
@end

@implementation LaunchAgentManager
- (NSURL *)plistURL {
    return [NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"Library/LaunchAgents/%@.plist", AppID]]];
}
- (BOOL)installed { return [NSFileManager.defaultManager fileExistsAtPath:self.plistURL.path]; }
- (void)setInstalled:(BOOL)enabled error:(NSError **)error {
    if (!enabled) return;
    NSString *exe = NSBundle.mainBundle.executableURL.path ?: NSProcessInfo.processInfo.arguments.firstObject;
    NSDictionary *plist = @{ @"Label": AppID, @"ProgramArguments": @[exe], @"RunAtLoad": @YES, @"LimitLoadToSessionType": @"Aqua" };
    [NSFileManager.defaultManager createDirectoryAtURL:self.plistURL.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:plist format:NSPropertyListXMLFormat_v1_0 options:0 error:error];
    if (!data) return;
    [data writeToURL:self.plistURL options:NSDataWritingAtomic error:error];
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/bin/launchctl";
    task.arguments = @[@"bootstrap", [NSString stringWithFormat:@"gui/%d", getuid()], self.plistURL.path];
    @try { [task launch]; [task waitUntilExit]; } @catch (__unused NSException *exception) {}
}
@end

@interface AppController : NSObject <NSApplicationDelegate, NSWindowDelegate>
@end

@implementation AppController {
    BluetoothManager *_bluetooth;
    Preferences *_preferences;
    LaunchAgentManager *_launchAgent;
    NSStatusItem *_statusItem;
    NSWindow *_window;
    NSPopUpButton *_devicePopup;
    NSTextField *_statusLabel;
    NSButton *_refreshButton;
    NSButton *_connectButton;
    NSButton *_disconnectButton;
    NSArray<IOBluetoothDevice *> *_devices;
    NSTimer *_statusTimer;
    NSTimer *_lockGuardTimer;
    NSTimer *_reconnectTimer;
    NSDate *_lockGuardStartedAt;
    NSDate *_reconnectStartedAt;
    BOOL _bluetoothActionInProgress;
    BOOL _sessionUnavailable;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    _bluetooth = [BluetoothManager new];
    _preferences = [Preferences new];
    _launchAgent = [LaunchAgentManager new];
    NSApp.activationPolicy = NSApplicationActivationPolicyAccessory;
    [self buildMenuBar];
    [self buildWindow];
    [self installObservers];
    [_launchAgent setInstalled:YES error:nil];
    [self refreshDevices];
    [self startStatusTimer];
    [self startReconnectWatcherBecause:@"app start"];
    [_window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)buildMenuBar {
    _statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:24.0];
    _statusItem.button.image = [self statusBarIconConnected:NO];
    _statusItem.button.imagePosition = NSImageOnly;
    _statusItem.button.toolTip = @"Forbidden Trackpad";
    NSMenu *menu = [NSMenu new];
    [menu addItemWithTitle:@"Open" action:@selector(openWindow) keyEquivalent:@"o"];
    [menu addItemWithTitle:@"Connect Selected Trackpad" action:@selector(connectSelected) keyEquivalent:@"c"];
    [menu addItemWithTitle:@"Forget Selected Trackpad" action:@selector(disconnectSelected) keyEquivalent:@"d"];
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItemWithTitle:@"Quit" action:@selector(terminate:) keyEquivalent:@"q"];
    _statusItem.menu = menu;
}

- (NSImage *)statusBarIconConnected:(BOOL)connected {
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(18, 18)];
    [image lockFocus];

    [[NSColor.labelColor colorWithAlphaComponent:(connected ? 1.0 : 0.38)] setStroke];

    NSBezierPath *trackpad = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(2.5, 4.0, 13.0, 10.5) xRadius:2.5 yRadius:2.5];
    trackpad.lineWidth = 1.7;
    [trackpad stroke];

    NSBezierPath *surface = [NSBezierPath bezierPath];
    [surface moveToPoint:NSMakePoint(5.0, 11.1)];
    [surface lineToPoint:NSMakePoint(13.0, 11.1)];
    surface.lineWidth = 1.2;
    [surface stroke];

    NSBezierPath *handoff = [NSBezierPath bezierPath];
    [handoff moveToPoint:NSMakePoint(7.0, 3.2)];
    [handoff curveToPoint:NSMakePoint(11.0, 3.2) controlPoint1:NSMakePoint(8.0, 2.2) controlPoint2:NSMakePoint(10.0, 2.2)];
    handoff.lineWidth = 1.5;
    handoff.lineCapStyle = NSLineCapStyleRound;
    [handoff stroke];

    NSBezierPath *spark = [NSBezierPath bezierPath];
    [spark moveToPoint:NSMakePoint(10.2, 15.6)];
    [spark lineToPoint:NSMakePoint(7.7, 9.8)];
    [spark lineToPoint:NSMakePoint(10.5, 9.8)];
    [spark lineToPoint:NSMakePoint(8.5, 5.2)];
    spark.lineWidth = 1.65;
    spark.lineJoinStyle = NSLineJoinStyleRound;
    spark.lineCapStyle = NSLineCapStyleRound;
    [spark stroke];

    [image unlockFocus];
    image.template = YES;
    return image;
}

- (void)buildWindow {
    _window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 520, 285) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable backing:NSBackingStoreBuffered defer:NO];
    _window.title = @"Forbidden Trackpad";
    _window.releasedWhenClosed = NO;
    _window.delegate = self;
    [_window center];

    NSStackView *root = [NSStackView new];
    root.orientation = NSUserInterfaceLayoutOrientationVertical;
    root.alignment = NSLayoutAttributeLeading;
    root.spacing = 14;
    root.edgeInsets = NSEdgeInsetsMake(22, 24, 20, 24);
    root.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField *title = [NSTextField labelWithString:@"Select one Bluetooth device"];
    title.font = [NSFont boldSystemFontOfSize:18];
    [root addArrangedSubview:title];

    NSTextField *text = [NSTextField wrappingLabelWithString:@"On lock this app forgets only the selected Bluetooth address. On unlock it tries to connect it again; macOS may ask you to allow the device."];
    text.textColor = NSColor.secondaryLabelColor;
    [root addArrangedSubview:text];

    _devicePopup = [NSPopUpButton new];
    _devicePopup.target = self;
    _devicePopup.action = @selector(deviceChanged);
    [_devicePopup.widthAnchor constraintEqualToConstant:460].active = YES;
    [root addArrangedSubview:_devicePopup];

    NSStackView *buttons = [NSStackView new];
    buttons.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    buttons.spacing = 10;
    _refreshButton = [self button:@"Refresh" action:@selector(refreshDevices)];
    _connectButton = [self button:@"Test Connect" action:@selector(connectSelected)];
    _disconnectButton = [self button:@"Test Forget" action:@selector(disconnectSelected)];
    [buttons addArrangedSubview:_refreshButton];
    [buttons addArrangedSubview:_connectButton];
    [buttons addArrangedSubview:_disconnectButton];
    [root addArrangedSubview:buttons];

    _statusLabel = [NSTextField wrappingLabelWithString:@""];
    _statusLabel.textColor = NSColor.secondaryLabelColor;
    [root addArrangedSubview:_statusLabel];

    _window.contentView = [NSView new];
    [_window.contentView addSubview:root];
    [NSLayoutConstraint activateConstraints:@[
        [root.leadingAnchor constraintEqualToAnchor:_window.contentView.leadingAnchor],
        [root.trailingAnchor constraintEqualToAnchor:_window.contentView.trailingAnchor],
        [root.topAnchor constraintEqualToAnchor:_window.contentView.topAnchor],
        [root.bottomAnchor constraintEqualToAnchor:_window.contentView.bottomAnchor]
    ]];
}

- (NSButton *)button:(NSString *)title action:(SEL)action {
    NSButton *button = [NSButton buttonWithTitle:title target:self action:action];
    button.bezelStyle = NSBezelStyleRounded;
    return button;
}

- (BOOL)windowShouldClose:(NSWindow *)sender { [sender orderOut:nil]; return NO; }
- (void)openWindow { [self refreshDevices]; [_window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES]; }

- (void)installObservers {
    NSNotificationCenter *workspace = NSWorkspace.sharedWorkspace.notificationCenter;
    [workspace addObserver:self selector:@selector(lockStarted:) name:NSWorkspaceSessionDidResignActiveNotification object:nil];
    [workspace addObserver:self selector:@selector(lockStarted:) name:NSWorkspaceWillSleepNotification object:nil];
    [workspace addObserver:self selector:@selector(lockStarted:) name:NSWorkspaceScreensDidSleepNotification object:nil];
    [workspace addObserver:self selector:@selector(unlockStarted:) name:NSWorkspaceSessionDidBecomeActiveNotification object:nil];
    [workspace addObserver:self selector:@selector(unlockStarted:) name:NSWorkspaceDidWakeNotification object:nil];
    [workspace addObserver:self selector:@selector(unlockStarted:) name:NSWorkspaceScreensDidWakeNotification object:nil];
    [NSDistributedNotificationCenter.defaultCenter addObserver:self selector:@selector(lockStarted:) name:@"com.apple.screenIsLocked" object:nil];
    [NSDistributedNotificationCenter.defaultCenter addObserver:self selector:@selector(unlockStarted:) name:@"com.apple.screenIsUnlocked" object:nil];
}

- (void)startStatusTimer {
    [_statusTimer invalidate];
    _statusTimer = [NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(__unused NSTimer *timer) { [self refreshStatusOnly]; }];
    _statusTimer.tolerance = 0.5;
}

- (void)startLockGuard {
    _lockGuardStartedAt = NSDate.date;
    [_lockGuardTimer invalidate];
    _lockGuardTimer = [NSTimer scheduledTimerWithTimeInterval:3 repeats:YES block:^(__unused NSTimer *timer) {
        if ([NSDate.date timeIntervalSinceDate:self->_lockGuardStartedAt] > 300) { [self stopLockGuard]; [self updateStatus:@"Lock guard stopped after 5 minutes."]; return; }
        [self disconnectBecause:@"lock guard"];
    }];
    _lockGuardTimer.tolerance = 0.5;
}
- (void)stopLockGuard { [_lockGuardTimer invalidate]; _lockGuardTimer = nil; }

- (void)startReconnectWatcherBecause:(NSString *)reason {
    NSString *address = _preferences.selectedAddress;
    if (!address.length) { [self updateStatus:@"Choose your Magic Trackpad first."]; return; }
    _sessionUnavailable = NO;
    _reconnectStartedAt = NSDate.date;
    [_reconnectTimer invalidate];
    [self updateStatus:[NSString stringWithFormat:@"Waiting for selected trackpad. Retrying every 10s because %@.", reason]];
    [self reconnectTickBecause:reason];
    _reconnectTimer = [NSTimer scheduledTimerWithTimeInterval:10 repeats:YES block:^(__unused NSTimer *timer) {
        [self reconnectTickBecause:reason];
    }];
    _reconnectTimer.tolerance = 1.0;
}

- (void)stopReconnectWatcher {
    [_reconnectTimer invalidate];
    _reconnectTimer = nil;
}

- (void)reconnectTickBecause:(NSString *)reason {
    if (_sessionUnavailable) return;
    if (_bluetoothActionInProgress) return;
    if ([NSDate.date timeIntervalSinceDate:_reconnectStartedAt] > 600) {
        [self stopReconnectWatcher];
        [self updateStatus:@"Stopped auto reconnect after 10 minutes. Tap or power-cycle the trackpad, then press Test Connect."];
        return;
    }

    NSString *address = _preferences.selectedAddress;
    if (!address.length) { [self stopReconnectWatcher]; [self updateStatus:@"Choose your Magic Trackpad first."]; return; }

    IOBluetoothDevice *device = [_bluetooth deviceForAddress:address];
    if (device.isConnected) {
        [self stopReconnectWatcher];
        [self refreshDevices];
        [self updateStatus:@"Selected trackpad is connected."];
        return;
    }

    [self connectBecause:[NSString stringWithFormat:@"auto reconnect (%@)", reason] completion:^{
        IOBluetoothDevice *current = [self->_bluetooth deviceForAddress:self->_preferences.selectedAddress];
        if (current.isConnected) {
            [self stopReconnectWatcher];
            [self updateStatus:@"Selected trackpad reconnected automatically."];
        } else if (self->_reconnectTimer) {
            [self updateStatus:@"Waiting for selected trackpad. Turn it on or tap it to wake. Retrying every 10s."];
        }
    }];
}

- (void)lockStarted:(NSNotification *)note {
    _sessionUnavailable = YES;
    [self stopReconnectWatcher];
    [self forgetBecause:note.name ?: @"lock"];
}
- (void)unlockStarted:(NSNotification *)note {
    [self stopLockGuard];
    [self startReconnectWatcherBecause:note.name ?: @"unlock"];
}

- (void)connectSelected { [self connectBecause:@"manual test"]; }
- (void)disconnectSelected { [self forgetBecause:@"manual test"]; }

- (void)connectBecause:(NSString *)reason {
    [self connectBecause:reason completion:nil];
}

- (void)connectBecause:(NSString *)reason completion:(void (^)(void))completion {
    NSString *address = _preferences.selectedAddress;
    if (!address.length) { [self updateStatus:@"Choose your Magic Trackpad first."]; return; }
    [self runBluetoothAction:[NSString stringWithFormat:@"Connecting because %@...", reason] success:[NSString stringWithFormat:@"Connected because %@.", reason] block:^(NSError **error) { [self->_bluetooth connectAddress:address error:error]; } completion:completion];
}
- (void)disconnectBecause:(NSString *)reason {
    NSString *address = _preferences.selectedAddress;
    if (!address.length) { [self updateStatus:@"Choose your Magic Trackpad first."]; return; }
    [self runBluetoothAction:[NSString stringWithFormat:@"Disconnecting because %@...", reason] success:[NSString stringWithFormat:@"Disconnected because %@.", reason] block:^(NSError **error) { [self->_bluetooth disconnectAddress:address error:error]; } completion:nil];
}

- (void)forgetBecause:(NSString *)reason {
    NSString *address = _preferences.selectedAddress;
    if (!address.length) { [self updateStatus:@"Choose your Magic Trackpad first."]; return; }
    [self runBluetoothAction:[NSString stringWithFormat:@"Forgetting because %@...", reason] success:[NSString stringWithFormat:@"Forgot because %@. On next connect, approve the macOS device prompt if it appears.", reason] block:^(NSError **error) { [self->_bluetooth forgetAddress:address error:error]; } completion:nil];
}

- (void)runBluetoothAction:(NSString *)start success:(NSString *)success block:(void (^)(NSError **error))block completion:(void (^)(void))completion {
    if (_bluetoothActionInProgress) { [self updateStatus:@"Bluetooth action already running."]; return; }
    _bluetoothActionInProgress = YES;
    [self setControlsEnabled:NO];
    [self updateStatus:start];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        block(&error);
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_bluetoothActionInProgress = NO;
            [self setControlsEnabled:YES];
            [self refreshDevices];
            [self updateStatus:error.localizedDescription ?: success];
            if (completion) completion();
        });
    });
}

- (void)setControlsEnabled:(BOOL)enabled { _devicePopup.enabled = enabled; _refreshButton.enabled = enabled; _connectButton.enabled = enabled; _disconnectButton.enabled = enabled; }

- (void)deviceChanged {
    BOOL placeholder = _preferences.selectedAddress.length == 0;
    NSInteger index = _devicePopup.indexOfSelectedItem - (placeholder ? 1 : 0);
    if (index < 0 || index >= (NSInteger)_devices.count) return;
    IOBluetoothDevice *device = _devices[index];
    [_preferences setSelectedAddress:device.addressString ?: @""];
    [self updateStatus:[NSString stringWithFormat:@"Selected %@ %@.", device.name ?: @"device", device.addressString.uppercaseString ?: @""]];
}

- (void)refreshStatusOnly {
    NSString *address = _preferences.selectedAddress;
    if (!address.length) return;
    IOBluetoothDevice *device = [_bluetooth deviceForAddress:address];
    _statusItem.button.image = [self statusBarIconConnected:device.isConnected];
}

- (void)refreshDevices {
    _devices = [_bluetooth pairedDevices];
    NSString *saved = _preferences.selectedAddress;
    NSMutableArray *mutable = [_devices mutableCopy];
    if (saved.length) {
        BOOL exists = NO;
        for (IOBluetoothDevice *device in mutable) if ([NormalizeAddress(device.addressString ?: @"") isEqualToString:saved]) exists = YES;
        if (!exists) { IOBluetoothDevice *device = [_bluetooth deviceForAddress:saved]; if (device) [mutable insertObject:device atIndex:0]; }
    }
    _devices = mutable;
    [_devicePopup removeAllItems];
    BOOL placeholder = saved.length == 0;
    if (placeholder) [_devicePopup addItemWithTitle:@"Choose trackpad..."];
    for (IOBluetoothDevice *device in _devices) {
        NSString *state = device.isConnected ? @"connected" : @"disconnected";
        [_devicePopup addItemWithTitle:[NSString stringWithFormat:@"%@  (%@) - %@", device.name ?: @"Saved Trackpad", (device.addressString ?: saved).uppercaseString, state]];
    }
    NSInteger selected = placeholder ? 0 : -1;
    for (NSUInteger i = 0; i < _devices.count; i++) if ([NormalizeAddress(_devices[i].addressString ?: @"") isEqualToString:saved]) selected = (NSInteger)i + (placeholder ? 1 : 0);
    if (selected >= 0) [_devicePopup selectItemAtIndex:selected];
    [self refreshStatusOnly];
    [self updateStatus:saved.length ? [NSString stringWithFormat:@"Ready. Selected address: %@.", saved.uppercaseString] : @"No device selected yet."];
}

- (void)updateStatus:(NSString *)message { _statusLabel.stringValue = message ?: @""; _statusItem.button.toolTip = [@"Forbidden Trackpad: " stringByAppendingString:message ?: @""]; }
@end

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        AppController *delegate = [AppController new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
