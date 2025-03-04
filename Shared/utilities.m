//
//  file: utilities.m
//  project: BlockBlock (shared)
//  description: various helper/utility functions
//
//  created by Patrick Wardle
//  copyright (c) 2017 Objective-See. All rights reserved.
//

#import "consts.h"
#import "logging.h"
#import "utilities.h"

#import <dlfcn.h>
#import <signal.h>
#import <unistd.h>
#import <libproc.h>
#import <sys/sysctl.h>
#import <Carbon/Carbon.h>
#import <Security/Security.h>
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <SystemConfiguration/SystemConfiguration.h>


//get app's version
// extracted from Info.plist
NSString* getAppVersion()
{
    //read and return 'CFBundleVersion' from bundle
    return [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleVersion"];
}

//given an app binary
// try get app's bundle
NSBundle* getAppBundle(NSString* binaryPath)
{
    //bundle
    NSBundle* appBundle = nil;
    
    //app path
    NSString* appPath = nil;
    
    //build app path
    // assuming path is <blah.app>/Contents/MacOS/<blah>
    appPath = [[[binaryPath stringByDeletingLastPathComponent] stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
    if(YES != [appPath hasSuffix:@".app"])
    {
        //bail
        goto bail;
    }
    
    //try to load app's bundle
    appBundle = [NSBundle bundleWithPath:appPath];
    if(nil == appBundle)
    {
        //bail
        goto bail;
    }
    
    //sanity check
    // binary paths match?
    if(YES != [appBundle.executablePath isEqualToString:binaryPath])
    {
        //unset
        appBundle = nil;
        
        //bail
        goto bail;
    }
    
bail:
    
    return appBundle;
}

//figure out binary's name
// either via app bundle, or from path
NSString* getBinaryName(NSString* path)
{
    //name
    NSString* name = nil;
    
    //bundle
    NSBundle* bundle = nil;
    
    //try get bundle
    // then extract name from 'CFBundleName'
    bundle = getAppBundle(path);
    if(nil != bundle)
    {
        //extract name
        name = [bundle infoDictionary][@"CFBundleName"];
    }
    
    //no app bundle || no 'CFBundleName'?
    // just use last component from the path
    if(nil == name)
    {
        //set name
        name = [path lastPathComponent];
    }
    
    return name;
}

//get path to (main) app of a login item
// login item is in app bundle, so parse up to get main app
NSString* getMainAppPath()
{
    //path components
    NSArray *pathComponents = nil;
    
    //path to config (main) app
    NSString* mainApp = nil;
    
    //get path components
    // then build full path to main app
    pathComponents = [[[NSBundle mainBundle] bundlePath] pathComponents];
    if(pathComponents.count > 4)
    {
        //init path to full (main) app
        mainApp = [NSString pathWithComponents:[pathComponents subarrayWithRange:NSMakeRange(0, pathComponents.count - 4)]];
    }
    
    //when (still) nil
    // use default path
    if(nil == mainApp)
    {
        //default
        mainApp = [@"/Applications" stringByAppendingPathComponent:APP_NAME];
    }
    
    return mainApp;
}

//give path to app
// get full path to its binary
NSString* getAppBinary(NSString* appPath)
{
    //binary path
    NSString* binaryPath = nil;
    
    //app bundle
    NSBundle* appBundle = nil;
    
    //load app bundle
    appBundle = [NSBundle bundleWithPath:appPath];
    if(nil == appBundle)
    {
        //err msg
        logMsg(LOG_ERR, [NSString stringWithFormat:@"failed to load app bundle for %@", appPath]);
        
        //bail
        goto bail;
    }
    
    //extract executable
    binaryPath = appBundle.executablePath;
    
bail:
    
    return binaryPath;
}


#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"

//get (true) parent
NSDictionary* getRealParent(pid_t pid)
{
    //process info
    NSDictionary* processInfo = nil;
    
    //process serial number
    ProcessSerialNumber psn = {0, kNoProcess};
    
    //(parent) process serial number
    ProcessSerialNumber ppsn = {0, kNoProcess};
    
    //get process serial number from pid
    if(noErr != GetProcessForPID(pid, &psn))
    {
        //err
        goto bail;
    }
    
    //get process (carbon) info
    processInfo = CFBridgingRelease(ProcessInformationCopyDictionary(&psn, (UInt32)kProcessDictionaryIncludeAllInformationMask));
    if(nil == processInfo)
    {
        //err
        goto bail;
    }
    
    //extract/convert parent ppsn
    ppsn.lowLongOfPSN =  [processInfo[@"ParentPSN"] longLongValue] & 0x00000000FFFFFFFFLL;
    ppsn.highLongOfPSN = ([processInfo[@"ParentPSN"] longLongValue] >> 32) & 0x00000000FFFFFFFFLL;
    
    //get parent process (carbon) info
    processInfo = CFBridgingRelease(ProcessInformationCopyDictionary(&ppsn, (UInt32)kProcessDictionaryIncludeAllInformationMask));
    if(nil == processInfo)
    {
        //err
        goto bail;
    }
    
bail:
    
    return processInfo;
}

#pragma GCC diagnostic pop

/*

//build an array of processes ancestry
// uses `GetProcessForPID` to try get (real) parent
NSMutableArray* generateProcessHierarchy(pid_t pid, NSString* name)
{
    //process hierarchy
    NSMutableArray* processHierarchy = nil;
    
    //current process id
    pid_t currentPID = -1;
    
    //parent pid
    pid_t parentPID = -1;
    
    //process name
    NSString* parentName = nil;
    
    //alloc
    processHierarchy = [NSMutableArray array];

    //parent
    NSDictionary* parent = nil;
    
    //add current process (leaf)
    // parent(s) will then be added at front...
    [processHierarchy addObject:[@{@"pid":[NSNumber numberWithInt:pid], @"name":valueForStringItem(name)} mutableCopy]];
    
    //init current to self
    currentPID = pid;
    
    //scan back
    while(YES)
    {
        //get (real) parent
        parent = getRealParent(currentPID);
        if(nil == parent)
        {
            break;
        }
        
        //get parent pid
        parentPID = [parent[@"pid"] intValue];
        
        //end of heirarchy?
        if( (0 == parentPID) ||
            (-1 == parentPID) ||
            (currentPID == parentPID) )
        {
            //bail
            break;
        }
        
        //get name
        // first from bundle, then from executable
        name = parent[@"CFBundleName"];
        if(0 == name.length)
        {
            //via executable
            name = [parent[@"CFBundleExecutable"] lastPathComponent];
        }
        
        //add parent
        // always at front
        [processHierarchy insertObject:[@{@"pid":[NSNumber numberWithInt:parentPID], @"name":valueForStringItem(parentName)} mutableCopy] atIndex:0];
        
        //update
        currentPID = parentPID;
    }
    
    return processHierarchy;
}
 
*/

//check if something is nil
// if so, return a default ('unknown') value
NSString* valueForStringItem(NSString* item)
{
    return (nil != item) ? item : @"unknown";
}

//find 'top-level' app of binary
// useful to determine if binary (or other app) is embedded in a 'parent' app bundle
NSString* topLevelApp(NSString* binaryPath)
{
    //app path
    NSString* appPath = nil;
    
    //offset of (first) '.app'
    NSRange offset;
    
    //find first instance of '.app' in path
    offset = [binaryPath rangeOfString:@".app/" options:NSCaseInsensitiveSearch];
    if(NSNotFound == offset.location)
    {
        //bail
        goto bail;
    }
    
    //extact app path
    // from start, to & including '.app'
    appPath = [binaryPath substringWithRange:NSMakeRange(0, offset.location+4)];

bail:
    
    return appPath;
}

//verify that an app bundle is valid
// signed & with (our) signing auth / identifier
OSStatus verifyApp(NSString* path, NSString* signingAuth)
{
    //status
    OSStatus status = !noErr;
    
    //signing req string
    NSString *requirement = nil;
    
    //code
    SecStaticCodeRef staticCode = NULL;
    
    //signing reqs
    SecRequirementRef requirementRef = NULL;
    
    //init signing req string
    requirement = [NSString stringWithFormat:@"anchor apple generic and identifier \"%@\" and certificate leaf [subject.CN] = \"%@\" and info [CFBundleShortVersionString] >= \"1.0.0\"", INSTALLER_ID, signingAuth];
    
    //create static code
    status = SecStaticCodeCreateWithPath((__bridge CFURLRef)([NSURL fileURLWithPath:path]), kSecCSDefaultFlags, &staticCode);
    if(noErr != status)
    {
        //err msg
        logMsg(LOG_ERR, [NSString stringWithFormat:@"SecStaticCodeCreateWithPath failed w/ %d", status]);
        
        //bail
        goto bail;
    }
    
    //create req string
    status = SecRequirementCreateWithString((__bridge CFStringRef _Nonnull)(requirement), kSecCSDefaultFlags, &requirementRef);
    if( (noErr != status) ||
       (requirementRef == NULL) )
    {
        //err msg
        logMsg(LOG_ERR, [NSString stringWithFormat:@"SecRequirementCreateWithString failed w/ %d", status]);
        
        //bail
        goto bail;
    }
    
    //check if file is signed w/ apple dev id by checking if it conforms to req string
    status = SecStaticCodeCheckValidity(staticCode, kSecCSDefaultFlags, requirementRef);
    if(noErr != status)
    {
        logMsg(LOG_ERR, [NSString stringWithFormat:@"SecStaticCodeCheckValidity failed w/ %d", status]);
        
        //bail
        goto bail;
    }
    
    //happy
    status = noErr;
    
bail:
    
    //free req reference
    if(NULL != requirementRef)
    {
        //free
        CFRelease(requirementRef);
        requirementRef = NULL;
    }
    
    //free static code
    if(NULL != staticCode)
    {
        //free
        CFRelease(staticCode);
        staticCode = NULL;
    }
    
    return status;
}

//get name of logged in user
NSString* getConsoleUser()
{
    //copy/return user
    return CFBridgingRelease(SCDynamicStoreCopyConsoleUser(NULL, NULL, NULL));
}

//get process name
// either via app bundle, or path
NSString* getProcessName(NSString* path)
{
    //process name
    NSString* processName = nil;
    
    //app bundle
    NSBundle* appBundle = nil;
    
    //try find an app bundle
    appBundle = findAppBundle(path);
    if(nil != appBundle)
    {
        //grab name from app's bundle
        processName = [appBundle infoDictionary][@"CFBundleName"];
    }
    
    //still nil?
    // ->just grab from path
    if(nil == processName)
    {
        //from path
        processName = [path lastPathComponent];
    }
    
    return processName;
}

//given a path to binary
// parse it back up to find app's bundle
NSBundle* findAppBundle(NSString* path)
{
    //app's bundle
    NSBundle* appBundle = nil;
    
    //standarized path
    NSString* standardedPath = nil;
    
    //app's path
    NSString* appPath = nil;
    
    //standardize path
    standardedPath = [[path stringByStandardizingPath] stringByResolvingSymlinksInPath];
    
    //first just try full path
    appPath = standardedPath;
    
    //try to find the app's bundle
    do
    {
        //try to load app's bundle
        appBundle = [NSBundle bundleWithPath:appPath];
        
        //was an app passed in?
        if(YES == [appBundle.bundlePath isEqualToString:standardedPath])
        {
            //all done
            break;
        }
        
        //check for match
        // binary path's match
        if( (nil != appBundle) &&
            (YES == [appBundle.executablePath isEqualToString:standardedPath]))
        {
            //all done
            break;
        }
        
        //unset
        appBundle = nil;
        
        //remove last part
        // will try this next
        appPath = [appPath stringByDeletingLastPathComponent];
        
    //scan until we get to root
    // of course, loop will exit if app info dictionary is found/loaded
    } while( (nil != appPath) &&
             (YES != [appPath isEqualToString:@"/"]) &&
             (YES != [appPath isEqualToString:@""]) );
    
    return appBundle;
}

//set dir's|file's group/owner
BOOL setFileOwner(NSString* path, NSNumber* groupID, NSNumber* ownerID, BOOL recursive)
{
    //ret var
    BOOL bSetOwner = NO;
    
    //owner dictionary
    NSDictionary* fileOwner = nil;
    
    //sub paths
    NSArray* subPaths = nil;
    
    //full path
    // ->for recursive
    NSString* fullPath = nil;
    
    //init permissions dictionary
    fileOwner = @{NSFileGroupOwnerAccountID:groupID, NSFileOwnerAccountID:ownerID};
    
    //set group/owner
    if(YES != [[NSFileManager defaultManager] setAttributes:fileOwner ofItemAtPath:path error:NULL])
    {
        //err msg
        logMsg(LOG_ERR, [NSString stringWithFormat:@"failed to set ownership for %@ (%@)", path, fileOwner]);
        
        //bail
        goto bail;
    }
    
    //dbg msg
    logMsg(LOG_DEBUG, [NSString stringWithFormat:@"set ownership for %@ (%@)", path, fileOwner]);
    
    //do it recursively
    if(YES == recursive)
    {
        //sanity check
        // ->make sure root starts with '/'
        if(YES != [path hasSuffix:@"/"])
        {
            //add '/'
            path = [NSString stringWithFormat:@"%@/", path];
        }
        
        //get all subpaths
        subPaths = [[NSFileManager defaultManager] subpathsAtPath:path];
        for(NSString *subPath in subPaths)
        {
            //init full path
            fullPath = [path stringByAppendingString:subPath];
            
            //set group/owner
            if(YES != [[NSFileManager defaultManager] setAttributes:fileOwner ofItemAtPath:fullPath error:NULL])
            {
                //err msg
                logMsg(LOG_ERR, [NSString stringWithFormat:@"failed to set ownership for %@ (%@)", fullPath, fileOwner]);
                
                //bail
                goto bail;
            }
        }
    }
    
    //no errors
    bSetOwner = YES;
    
//bail
bail:
    
    return bSetOwner;
}

//set permissions for file
BOOL setFilePermissions(NSString* file, int permissions, BOOL recursive)
{
    //ret var
    BOOL bSetPermissions = NO;
    
    //file permissions
    NSDictionary* filePermissions = nil;
    
    //root directory
    NSURL* root = nil;
    
    //directory enumerator
    NSDirectoryEnumerator* enumerator = nil;
    
    //error
    NSError* error = nil;
    
    //init dictionary
    filePermissions = @{NSFilePosixPermissions: [NSNumber numberWithInt:permissions]};
    
    //apply file permissions recursively
    if(YES == recursive)
    {
        //init root
        root = [NSURL fileURLWithPath:file];
        
        //init enumerator
        enumerator = [[NSFileManager defaultManager] enumeratorAtURL:root includingPropertiesForKeys:[NSArray arrayWithObject:NSURLIsDirectoryKey] options:0 errorHandler:nil];
    
        //set file permissions on each
        for(NSURL* currentFile in enumerator)
        {
            //set permissions
            if(YES != [[NSFileManager defaultManager] setAttributes:filePermissions ofItemAtPath:currentFile.path error:&error])
            {
                //err msg
                logMsg(LOG_ERR, [NSString stringWithFormat:@"failed to set permissions for %@ (%@), %@", currentFile.path, filePermissions, error]);
                
                //bail
                goto bail;
            }
        }
    }
    
    //always set permissions on passed in file (or top-level directory)
    // note: recursive enumerator skips root directory, so execute this always
    if(YES != [[NSFileManager defaultManager] setAttributes:filePermissions ofItemAtPath:file error:NULL])
    {
        //err msg
        logMsg(LOG_ERR, [NSString stringWithFormat:@"failed to set permissions for %@ (%@)", file, filePermissions]);
        
        //bail
        goto bail;
    }
    
    //happy
    bSetPermissions = YES;
    
bail:
    
    return bSetPermissions;
}

//get process's path
NSString* getProcessPath(pid_t pid)
{
    //task path
    NSString* processPath = nil;
    
    //buffer for process path
    char pathBuffer[PROC_PIDPATHINFO_MAXSIZE] = {0};
    
    //status
    int status = -1;
    
    //'management info base' array
    int mib[3] = {0};
    
    //system's size for max args
    unsigned long systemMaxArgs = 0;
    
    //process's args
    char* taskArgs = NULL;
    
    //# of args
    int numberOfArgs = 0;
    
    //size of buffers, etc
    size_t size = 0;
    
    //reset buffer
    memset(pathBuffer, 0x0, PROC_PIDPATHINFO_MAXSIZE);
    
    //first attempt to get path via 'proc_pidpath()'
    status = proc_pidpath(pid, pathBuffer, sizeof(pathBuffer));
    if(0 != status)
    {
        //init task's name
        processPath = [NSString stringWithUTF8String:pathBuffer];
    }
    //otherwise
    // try via task's args ('KERN_PROCARGS2')
    else
    {
        //init mib
        // ->want system's size for max args
        mib[0] = CTL_KERN;
        mib[1] = KERN_ARGMAX;
        
        //set size
        size = sizeof(systemMaxArgs);
        
        //get system's size for max args
        if(-1 == sysctl(mib, 2, &systemMaxArgs, &size, NULL, 0))
        {
            //bail
            goto bail;
        }
        
        //alloc space for args
        taskArgs = malloc(systemMaxArgs);
        if(NULL == taskArgs)
        {
            //bail
            goto bail;
        }
        
        //init mib
        // ->want process args
        mib[0] = CTL_KERN;
        mib[1] = KERN_PROCARGS2;
        mib[2] = pid;
        
        //set size
        size = (size_t)systemMaxArgs;
        
        //get process's args
        if(-1 == sysctl(mib, 3, taskArgs, &size, NULL, 0))
        {
            //bail
            goto bail;
        }
        
        //sanity check
        // ensure buffer is somewhat sane
        if(size <= sizeof(int))
        {
            //bail
            goto bail;
        }
        
        //extract number of args
        memcpy(&numberOfArgs, taskArgs, sizeof(numberOfArgs));
        
        //extract task's name
        // follows # of args (int) and is NULL-terminated
        processPath = [NSString stringWithUTF8String:taskArgs + sizeof(int)];
    }
    
bail:
    
    //free process args
    if(NULL != taskArgs)
    {
        //free
        free(taskArgs);
        
        //reset
        taskArgs = NULL;
    }
    
    return processPath;
}

//given a process path and user
// return array of all matching pids
NSMutableArray* getProcessIDs(NSString* processPath, int userID)
{
    //status
    int status = -1;
    
    //process IDs
    NSMutableArray* processIDs = nil;
    
    //# of procs
    int numberOfProcesses = 0;
        
    //array of pids
    pid_t* pids = NULL;
    
    //process info struct
    struct kinfo_proc procInfo;
    
    //size of struct
    size_t procInfoSize = sizeof(procInfo);
    
    //mib
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, -1};
    
    //clear buffer
    memset(&procInfo, 0x0, procInfoSize);
    
    //get # of procs
    numberOfProcesses = proc_listallpids(NULL, 0);
    if(-1 == numberOfProcesses)
    {
        //bail
        goto bail;
    }
    
    //alloc buffer for pids
    pids = calloc((unsigned long)numberOfProcesses, sizeof(pid_t));
    
    //alloc
    processIDs = [NSMutableArray array];
    
    //get list of pids
    status = proc_listallpids(pids, numberOfProcesses * (int)sizeof(pid_t));
    if(status < 0)
    {
        //bail
        goto bail;
    }
        
    //iterate over all pids
    // ->get name for each process
    for(int i = 0; i < (int)numberOfProcesses; i++)
    {
        //skip blank pids
        if(0 == pids[i])
        {
            //skip
            continue;
        }
        
        //skip if path doesn't match
        if(YES != [processPath isEqualToString:getProcessPath(pids[i])])
        {
            //next
            continue;
        }
        
        //need to also match on user?
        // caller can pass in -1 to skip this check
        if(-1 != userID)
        {
            //init mib
            mib[0x3] = pids[i];
            
            //make syscall to get proc info for user
            if( (0 != sysctl(mib, 0x4, &procInfo, &procInfoSize, NULL, 0)) ||
                (0 == procInfoSize) )
            {
                //skip
                continue;
            }

            //skip if user id doesn't match
            if(userID != (int)procInfo.kp_eproc.e_ucred.cr_uid)
            {
                //skip
                continue;
            }
        }
        
        //got match
        // add to list
        [processIDs addObject:[NSNumber numberWithInt:pids[i]]];
    }
    
bail:
        
    //free buffer
    if(NULL != pids)
    {
        //free
        free(pids);
        
        //reset
        pids = NULL;
    }
    
    return processIDs;
}

//enable/disable a menu
void toggleMenu(NSMenu* menu, BOOL shouldEnable)
{
    //disable autoenable
    menu.autoenablesItems = NO;
    
    //iterate over
    // set state of each item
    for(NSMenuItem* item in menu.itemArray)
    {
        //set state
        item.enabled = shouldEnable;
    }
    
    return;
}

//get an icon for a process
// for apps, this will be app's icon, otherwise just a standard system one
NSImage* getIconForProcess(NSString* path)
{
    //icon's file name
    NSString* iconFile = nil;
    
    //icon's path
    NSString* iconPath = nil;
    
    //icon's path extension
    NSString* iconExtension = nil;
    
    //icon
    NSImage* icon = nil;
    
    //system's document icon
    static NSImage* documentIcon = nil;
    
    //bundle
    NSBundle* appBundle = nil;
    
    //invalid path?
    // grab a default icon and bail
    if(YES != [[NSFileManager defaultManager] fileExistsAtPath:path])
    {
        //set icon to system 'application' icon
        icon = [[NSWorkspace sharedWorkspace]
                iconForFileType: NSFileTypeForHFSTypeCode(kGenericApplicationIcon)];
        
        //set size to 64 @2x
        [icon setSize:NSMakeSize(128, 128)];
   
        //bail
        goto bail;
    }
    
    //first try grab bundle
    // then extact icon from this
    appBundle = findAppBundle(path);
    if(nil != appBundle)
    {
        //extract icon
        icon = [[NSWorkspace sharedWorkspace] iconForFile:appBundle.bundlePath];
        if(nil != icon)
        {
            //done!
            goto bail;
        }
        
        //get file
        iconFile = appBundle.infoDictionary[@"CFBundleIconFile"];
        
        //get path extension
        iconExtension = [iconFile pathExtension];
        
        //if its blank (i.e. not specified)
        // go with 'icns'
        if(YES == [iconExtension isEqualTo:@""])
        {
            //set type
            iconExtension = @"icns";
        }
        
        //set full path
        iconPath = [appBundle pathForResource:[iconFile stringByDeletingPathExtension] ofType:iconExtension];
        
        //load it
        icon = [[NSImage alloc] initWithContentsOfFile:iconPath];
    }
    
    //process is not an app or couldn't get icon
    // try to get it via shared workspace
    if( (nil == appBundle) ||
        (nil == icon) )
    {
        //extract icon
        icon = [[NSWorkspace sharedWorkspace] iconForFile:path];
        
        //load system document icon
        // static var, so only load once
        if(nil == documentIcon)
        {
            //load
            documentIcon = [[NSWorkspace sharedWorkspace] iconForFileType:
                            NSFileTypeForHFSTypeCode(kGenericDocumentIcon)];
        }
        
        //if 'iconForFile' method doesn't find and icon, it returns the system 'document' icon
        // the system 'application' icon seems more applicable, so use that here...
        if(YES == [icon isEqual:documentIcon])
        {
            //set icon to system 'application' icon
            icon = [[NSWorkspace sharedWorkspace]
                    iconForFileType: NSFileTypeForHFSTypeCode(kGenericApplicationIcon)];
        }
        
        //'iconForFileType' returns small icons
        // so set size to 64 @2x
        [icon setSize:NSMakeSize(128, 128)];
    }
    
bail:
    
    return icon;
}

//wait until a window is non nil
// then make it modal
void makeModal(NSWindowController* windowController)
{
    //wait up to 1 second window to be non-nil
    // then make modal
    for(int i=0; i<20; i++)
    {
        //can make it modal once we have a window
        if(nil != windowController.window)
        {
            //make modal on main thread
            dispatch_sync(dispatch_get_main_queue(), ^{
                
                //modal
                [[NSApplication sharedApplication] runModalForWindow:windowController.window];
                
            });
            
            //all done
            break;
        }
        
        //nap
        [NSThread sleepForTimeInterval:0.05f];
        
    }//until 1 second
    
    return;
}

//find a process by name
pid_t findProcess(NSString* processName)
{
    //pid
    pid_t processID = 0;
    
    //status
    int status = -1;
    
    //# of procs
    int numberOfProcesses = 0;
    
    //array of pids
    pid_t* pids = NULL;
    
    //process path
    NSString* processPath = nil;
    
    //get # of procs
    numberOfProcesses = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if(-1 == numberOfProcesses)
    {
        //bail
        goto bail;
    }
    
    //alloc buffer for pids
    pids = calloc((unsigned long)numberOfProcesses, sizeof(pid_t));
    
    //get list of pids
    status = proc_listpids(PROC_ALL_PIDS, 0, pids, numberOfProcesses * (int)sizeof(pid_t));
    if(status < 0)
    {
        //bail
        goto bail;
    }
    
    //iterate over all pids
    // get name for each via helper function
    for(int i = 0; i < numberOfProcesses; ++i)
    {
        //skip blank pids
        if(0 == pids[i])
        {
            //skip
            continue;
        }
        
        //get name
        processPath = getProcessPath(pids[i]);
        if( (nil == processPath) ||
           (0 == processPath.length) )
        {
            //skip
            continue;
        }
        
        //match?
        if(YES == [processPath isEqualToString:processName])
        {
            //save
            processID = pids[i];
            
            //pau
            break;
        }
        
    }//all procs
    
bail:
    
    //free buffer
    if(NULL != pids)
    {
        //free
        free(pids);
    }
    
    return processID;
}

//for login item enable/disable
// we use the launch services APIs, since replacements don't always work :(
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

//toggle login item
// either add (install) or remove (uninstall)
BOOL toggleLoginItem(NSURL* loginItem, int toggleFlag)
{
    //flag
    BOOL wasToggled = NO;
    
    //login item ref
    LSSharedFileListRef loginItemsRef = NULL;
    
    //login items
    CFArrayRef loginItems = NULL;
    
    //current login item
    CFURLRef currentLoginItem = NULL;
    
    //get reference to login items
    loginItemsRef = LSSharedFileListCreate(NULL, kLSSharedFileListSessionLoginItems, NULL);
    
    //add (install)
    if(ACTION_INSTALL_FLAG == toggleFlag)
    {
        //dbg msg
        logMsg(LOG_DEBUG, [NSString stringWithFormat:@"adding login item %@", loginItem]);
        
        //add
        LSSharedFileListItemRef itemRef = LSSharedFileListInsertItemURL(loginItemsRef, kLSSharedFileListItemLast, NULL, NULL, (__bridge CFURLRef)(loginItem), NULL, NULL);
        
        //release item ref
        if(NULL != itemRef)
        {
            //dbg msg
            logMsg(LOG_DEBUG, [NSString stringWithFormat:@"added %@/%@", loginItem, itemRef]);
            
            //release
            CFRelease(itemRef);
            
            //reset
            itemRef = NULL;
        }
        //failed
        else
        {
            //err msg
            logMsg(LOG_ERR, @"failed to add login item");
            
            //bail
            goto bail;
        }
        
        //happy
        wasToggled = YES;
    }
    //remove (uninstall)
    else
    {
        //dbg msg
        logMsg(LOG_DEBUG, [NSString stringWithFormat:@"removing login item %@", loginItem]);
        
        //grab existing login items
        loginItems = LSSharedFileListCopySnapshot(loginItemsRef, nil);
        
        //iterate over all login items
        // look for self, then remove it
        for(id item in (__bridge NSArray *)loginItems)
        {
            //get current login item
            currentLoginItem = LSSharedFileListItemCopyResolvedURL((__bridge LSSharedFileListItemRef)item, 0, NULL);
            if(NULL == currentLoginItem)
            {
                //skip
                continue;
            }
            
            //current login item match self?
            if(YES == [(__bridge NSURL *)currentLoginItem isEqual:loginItem])
            {
                //remove
                if(noErr != LSSharedFileListItemRemove(loginItemsRef, (__bridge LSSharedFileListItemRef)item))
                {
                    //err msg
                    logMsg(LOG_ERR, @"failed to remove login item");
                    
                    //bail
                    goto bail;
                }
                
                //dbg msg
                logMsg(LOG_DEBUG, [NSString stringWithFormat:@"removed login item: %@", loginItem]);
                
                //happy
                wasToggled = YES;
                
                //all done
                goto bail;
            }
            
            //release
            CFRelease(currentLoginItem);
            
            //reset
            currentLoginItem = NULL;
            
        }//all login items
        
    }//remove/uninstall
    
bail:
    
    //release login items
    if(NULL != loginItems)
    {
        //release
        CFRelease(loginItems);
        
        //reset
        loginItems = NULL;
    }
    
    //release login ref
    if(NULL != loginItemsRef)
    {
        //release
        CFRelease(loginItemsRef);
        
        //reset
        loginItemsRef = NULL;
    }
    
    //release url
    if(NULL != currentLoginItem)
    {
        //release
        CFRelease(currentLoginItem);
        
        //reset
        currentLoginItem = NULL;
    }
    
    return wasToggled;
}

#pragma clang diagnostic pop

//check if process is alive
BOOL isProcessAlive(pid_t processID)
{
    //ret var
    BOOL bIsAlive = NO;
    
    //signal status
    int signalStatus = -1;
    
    //send kill with 0 to determine if alive
    signalStatus = kill(processID, 0);
    
    //is alive?
    if( (0 == signalStatus) ||
        ((0 != signalStatus) && (errno != ESRCH)) )
    {
        //alive!
        bIsAlive = YES;
    }
    
    return bIsAlive;
}


//hash a file
NSMutableString* hashFile(NSString* filePath)
{
    //file's contents
    NSData* fileContents = nil;
    
    //hash digest
    uint8_t digestSHA256[CC_SHA256_DIGEST_LENGTH] = {0};
    
    //hash as string
    NSMutableString* sha256 = nil;
    
    //index var
    NSUInteger index = 0;
    
    //init
    sha256 = [NSMutableString string];
    
    //load file
    if(nil == (fileContents = [NSData dataWithContentsOfFile:filePath]))
    {
        //bail
        goto bail;
    }
    
    //sha256 it
    CC_SHA256(fileContents.bytes, (unsigned int)fileContents.length, digestSHA256);
    
    //convert to NSString
    // iterate over each bytes in computed digest and format
    for(index=0; index < CC_SHA256_DIGEST_LENGTH; index++)
    {
        //format/append
        [sha256 appendFormat:@"%02lX", (unsigned long)digestSHA256[index]];
    }
    
bail:
    
    return sha256;
}

/*

//given a pid, get its parent (ppid)
pid_t getParentID(int pid)
{
    //parent id
    pid_t parentID = -1;
    
    //kinfo_proc struct
    struct kinfo_proc processStruct;
    
    //size
    size_t procBufferSize = sizeof(processStruct);
    
    //mib
    const u_int mibLength = 4;
    
    //syscall result
    int sysctlResult = -1;
    
    //init mib
    int mib[mibLength] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
    
    //clear buffer
    memset(&processStruct, 0x0, procBufferSize);
    
    //make syscall
    sysctlResult = sysctl(mib, mibLength, &processStruct, &procBufferSize, NULL, 0);
    
    //check if got ppid
    if( (noErr == sysctlResult) &&
        (0 != procBufferSize) )
    {
        //save ppid
        parentID = processStruct.kp_eproc.e_ppid;
        
        //dbg msg
        logMsg(LOG_DEBUG, [NSString stringWithFormat:@"extracted parent ID %d for process: %d", parentID, pid]);
    }
    
    return parentID;
}
 
*/

//start app
// note: executed with 'NSWorkspaceLaunchWithoutActivation'
BOOL startApplication(NSURL* path, NSUInteger launchOptions)
{
    //status var
    BOOL result = NO;
    
    //error
    NSError* error = nil;
    
    //dbg msg
    logMsg(LOG_DEBUG, [NSString stringWithFormat:@"starting application: %@", path]);
    
    //launch it
    if(nil == [[NSWorkspace sharedWorkspace] launchApplicationAtURL:path options:launchOptions configuration:@{} error:&error])
    {
        //err msg
        logMsg(LOG_ERR, [NSString stringWithFormat:@"failed to launch application: %@/%@", path, error]);
        
        //bail
        goto bail;
    }
    
    //happy
    result = YES;
    
bail:
    
    return result;
}

//wait for file to be written to disk
void waitForFile(NSString* path, float maxWait)
{
    //wait interval
    float waitInterval = 0.1f;
    
    //count var for loop
    NSUInteger count = 0;
    
    //wait for file
    do
    {
        //wait for file
        if(YES == [[NSFileManager defaultManager] fileExistsAtPath:path])
        {
            //happy
            break;
        }
        
        //nap
        [NSThread sleepForTimeInterval:waitInterval];
        
    //try up to specified max
    } while(count++ < maxWait/waitInterval);
}

//given a bundle path
// wait for plist, then load bundle
NSBundle* getBundle(NSString* path, float maxWait)
{
    //bundle
    NSBundle* bundle = nil;
    
    //plist path
    NSString* plist = nil;
    
    //sanity check
    if(nil == path) goto bail;
    
    //init path to plist in bundle
    plist = [NSString pathWithComponents:@[path, @"/Contents/Info.plist"]];
    
    //wait for plist
    // indicator that bundle 'ready'
    waitForFile(plist, maxWait);
    
    //now load bundle
    bundle = [NSBundle bundleWithPath:path];
    
bail:
    
    //load/return bundle
    return bundle;
}

//extract value from plist
// takes optional wait time...
id getValueFromPlist(NSString* plistFile, NSString* plistKey, BOOL insensitiveKey, float maxWait)
{
    //return var
    id plistValue;
    
    //contents of plist
    NSDictionary* plistContents = nil;
    
    //wait for file
    waitForFile(plistFile, maxWait);
    
    //load it
    plistContents = [NSDictionary dictionaryWithContentsOfFile:plistFile];
    if(nil == plistContents)
    {
        //dbg msg
        logMsg(LOG_DEBUG, [NSString stringWithFormat:@"failed to open/read %@", plistFile]);
        
        //bail
        goto bail;
    }
    
    //try grab value
    plistValue = plistContents[plistKey];
    
    //not found?
    // try insensitve search
    if( (nil == plistValue) &&
        (YES == insensitiveKey))
    {
        //search all keys
        for(NSString* key in plistContents)
        {
            //key match?
            // extract value
            if(YES == [key.lowercaseString isEqualToString:plistKey.lowercaseString])
            {
                //found!
                plistValue = plistContents[key];
                
                //done
                break;
            }
        }
    }
    
bail:
    
    return plistValue;
}

//exec a process with args
// if 'shouldWait' is set, wait and return stdout/in and termination status
NSMutableDictionary* execTask(NSString* binaryPath, NSArray* arguments, BOOL shouldWait, BOOL grabOutput)
{
    //task
    NSTask* task = nil;
    
    //output pipe for stdout
    NSPipe* stdOutPipe = nil;
    
    //output pipe for stderr
    NSPipe* stdErrPipe = nil;
    
    //read handle for stdout
    NSFileHandle* stdOutReadHandle = nil;
    
    //read handle for stderr
    NSFileHandle* stdErrReadHandle = nil;
    
    //results dictionary
    NSMutableDictionary* results = nil;
    
    //output for stdout
    NSMutableData *stdOutData = nil;
    
    //output for stderr
    NSMutableData *stdErrData = nil;
    
    //init dictionary for results
    results = [NSMutableDictionary dictionary];
    
    //init task
    task = [[NSTask alloc] init];
    
    //sanity check
    // NSTask throws if path isn't found...
    if(YES != [NSFileManager.defaultManager fileExistsAtPath:binaryPath])
    {
        //bail
        goto bail;
    }
    
    //only setup pipes if wait flag is set
    if(YES == grabOutput)
    {
        //init stdout pipe
        stdOutPipe = [NSPipe pipe];
        
        //init stderr pipe
        stdErrPipe = [NSPipe pipe];
        
        //init stdout read handle
        stdOutReadHandle = [stdOutPipe fileHandleForReading];
        
        //init stderr read handle
        stdErrReadHandle = [stdErrPipe fileHandleForReading];
        
        //init stdout output buffer
        stdOutData = [NSMutableData data];
        
        //init stderr output buffer
        stdErrData = [NSMutableData data];
        
        //set task's stdout
        task.standardOutput = stdOutPipe;
        
        //set task's stderr
        task.standardError = stdErrPipe;
    }
    
    //set task's path
    task.launchPath = binaryPath;
    
    //set task's args
    if(nil != arguments)
    {
        //set
        task.arguments = arguments;
    }
    
    //dbg msg
    logMsg(LOG_DEBUG, [NSString stringWithFormat:@"execing task, %@ (arguments: %@)", task.launchPath, task.arguments]);
    
    //wrap task launch
    @try
    {
        //launch
        [task launch];
    }
    @catch(NSException *exception)
    {
        //err msg
        logMsg(LOG_ERR, [NSString stringWithFormat:@"failed to launch task (%@)", exception]);
        
        //bail
        goto bail;
    }
    
    //no need to wait
    // can just bail w/ no output
    if( (YES != shouldWait) &&
        (YES != grabOutput) )
    {
        //bail
        goto bail;
    }
    
    //wait
    // ...but no output
    else if( (YES == shouldWait) &&
             (YES != grabOutput) )
    {
        //wait
        [task waitUntilExit];
        
        //add exit code
        results[EXIT_CODE] = [NSNumber numberWithInteger:task.terminationStatus];
        
        //bail
        goto bail;
    }
    
    //grab output?
    // even if wait not set, still will wait!
    else
    {
        //read in stdout/stderr
        while(YES == [task isRunning])
        {
            //accumulate stdout
            [stdOutData appendData:[stdOutReadHandle readDataToEndOfFile]];
            
            //accumulate stderr
            [stdErrData appendData:[stdErrReadHandle readDataToEndOfFile]];
        }
        
        //grab any leftover stdout
        [stdOutData appendData:[stdOutReadHandle readDataToEndOfFile]];
        
        //grab any leftover stderr
        [stdErrData appendData:[stdErrReadHandle readDataToEndOfFile]];
        
        //add stdout
        if(0 != stdOutData.length)
        {
            //add
            results[STDOUT] = stdOutData;
        }
        
        //add stderr
        if(0 != stdErrData.length)
        {
            //add
            results[STDERR] = stdErrData;
        }
        
        //add exit code
        results[EXIT_CODE] = [NSNumber numberWithInteger:task.terminationStatus];
    }

bail:
    
    //dbg msg
    logMsg(LOG_DEBUG, [NSString stringWithFormat:@"task completed with %@", results]);
    
    return results;
}


//loads a framework
// note: assumes it is in 'Framework' dir
NSBundle* loadFramework(NSString* name)
{
    //handle
    NSBundle* framework = nil;
    
    //framework path
    NSString* path = nil;
    
    //init path
    path = [NSString stringWithFormat:@"%@/../Frameworks/%@", [NSProcessInfo.processInfo.arguments[0] stringByDeletingLastPathComponent], name];
    
    //standardize path
    path = [path stringByStandardizingPath];
    
    //init framework (bundle)
    framework = [NSBundle bundleWithPath:path];
    if(NULL == framework)
    {
        //bail
        goto bail;
    }
    
    //load framework
    if(YES != [framework loadAndReturnError:nil])
    {
        //bail
        goto bail;
    }
    
bail:
    
    return framework;
}

//check if a file is restricted (SIP)
BOOL isFileRestricted(NSString* file)
{
    //flag
    BOOL restricted = NO;
    
    //info
    struct stat info = {0};
    
    //clear
    memset(&info, 0x0, sizeof(struct stat));
    
    //get file info
    if(0 == lstat(file.UTF8String, &info))
    {
        //check flags
        restricted = (BOOL)(info.st_flags & SF_RESTRICTED);
    }
    
    return restricted;
}

//in dark mode?
BOOL isDarkMode()
{
    return [[[NSUserDefaults standardUserDefaults] stringForKey:@"AppleInterfaceStyle"] isEqualToString:@"Dark"];
}

//determine if path is translocated
// thanks: http://lapcatsoftware.com/articles/detect-app-translocation.html
BOOL isTranslocated(NSString* path)
{
    //flag
    BOOL isTranslocated = NO;
    
    //token
    static dispatch_once_t onceToken = 0;
    
    //framework handle
    static void* handle = NULL;
    
    //fp to 'SecTranslocateIsTranslocatedURL'
    static Boolean (*SecTranslocateIsTranslocatedURLFP)(CFURLRef path, bool *isTranslocated, CFErrorRef * __nullable error) = NULL;
    
    //flag for call
    bool translocated = false;
    
    //dbg msg
    logMsg(LOG_DEBUG, [NSString stringWithFormat:@"checking if %@ is translocated", path]);

    //load/open framework
    dispatch_once(&onceToken, ^{
        
        //open and resolve 'SecTranslocateIsTranslocatedURLFP'
        handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY);
        if(NULL != handle)
        {
            //resolve 'SecTranslocateIsTranslocatedURLFP'
            SecTranslocateIsTranslocatedURLFP = dlsym(handle, "SecTranslocateIsTranslocatedURL");
        }
        //err
        else
        {
            //err msg
            logMsg(LOG_ERR, @"failed to 'dlopen' the 'Security.framework'");
        }
        
    });
    
    //sanity check
    if(NULL == SecTranslocateIsTranslocatedURLFP)
    {
        //err msg
        logMsg(LOG_ERR, @"failed to resolve 'SecTranslocateIsTranslocatedURL'");
        
        //bail
        goto bail;
    }
    
    //call 'SecTranslocateIsTranslocatedURL'
    if(!SecTranslocateIsTranslocatedURLFP((__bridge CFURLRef)([NSURL fileURLWithPath:path]), &translocated, NULL))
    {
        //err msg
        logMsg(LOG_ERR, @"failed to invoke 'SecTranslocateIsTranslocatedURLFP'");
        
        //bail
        goto bail;
    }
    
    //log msg
    logMsg(LOG_DEBUG, [NSString stringWithFormat:@"SecTranslocateIsTranslocatedURL succeeded, result: %x", translocated]);
    
    //happy
    isTranslocated = translocated;
    
bail:

    return isTranslocated;
}

#ifdef DAEMON_BUILD

//mach time to nanoseconds
// from: https://developer.apple.com/documentation/apple-silicon/addressing-architectural-differences-in-your-macos-code
uint64_t machTimeToNanoseconds(uint64_t machTime)
{
    uint64_t nanoseconds = 0;
    static mach_timebase_info_data_t sTimebase;
    if (sTimebase.denom == 0)
        (void)mach_timebase_info(&sTimebase);

    nanoseconds = ((machTime * sTimebase.numer) / sTimebase.denom);

    return nanoseconds;
}

//get items quarantine flags
// thanks: https://trac.webkit.org/changeset/281056/webkit
uint32_t getQuarantineFlags(NSString* path)
{
    //error
    int error = noErr;
    
    //flags
    uint32_t flags = QTN_NOT_QUARANTINED;
    
    //once token
    static dispatch_once_t onceToken = 0;
    
    //dylib handle
    static void* handle = NULL;
    
    //function pointers
    static qtn_file_t(*qtn_file_alloc_FP)(void) = NULL;
    static void (*qtn_file_free_FP)(qtn_file_t qf) = NULL;
    static uint32_t (*qtn_file_get_flags_FP)(qtn_file_t qf) = NULL;
    static int (*qtn_file_init_with_path_FP)(qtn_file_t qf, const char *path) = NULL;
    
    //quarantine file
    qtn_file_t quarantineFile = NULL;
    
    //dbg msg
    logMsg(LOG_DEBUG, [NSString stringWithFormat:@"checking if %@ is quarantined", path]);
    
    //sanity check(s)
    if(0 == path.length)
    {
        //err msg
        logMsg(LOG_DEBUG, @"invalid path");
        
        //bail
        goto bail;
    }

    //load/open framework
    dispatch_once(&onceToken, ^{
        
        //open quarantine dylib
        handle = dlopen("/usr/lib/system/libquarantine.dylib", RTLD_LAZY);
        if(NULL != handle)
        {
            //resolve function pointers
            qtn_file_free_FP = dlsym(handle, "_qtn_file_free");
            qtn_file_alloc_FP = dlsym(handle, "_qtn_file_alloc");
            qtn_file_get_flags_FP = dlsym(handle, "_qtn_file_get_flags");
            qtn_file_init_with_path_FP = dlsym(handle, "_qtn_file_init_with_path");
        }
        //err
        else
        {
            //err msg
            logMsg(LOG_ERR, @"failed to 'dlopen' the 'libquarantine.dylib'");
        }
        
    });
    
    //sanity check(s)
    if( (NULL == qtn_file_free_FP) ||
        (NULL == qtn_file_alloc_FP) ||
        (NULL == qtn_file_get_flags_FP) ||
        (NULL == qtn_file_init_with_path_FP) )
    {
        //err msg
        logMsg(LOG_ERR, @"failed to resolve 'libquarantine' function pointers");
        
        //bail
        goto bail;
    }
    
    //alloc file
    quarantineFile = qtn_file_alloc_FP();
    if(NULL == quarantineFile)
    {
        //bail
        goto bail;
    }
    
    //init file
    error = qtn_file_init_with_path_FP(quarantineFile, [NSURL fileURLWithPath:path].path.fileSystemRepresentation);
    if(ENOENT == error)
    {
        //bail
        goto bail;
    }
    
    //not quarantined?
    if(QTN_NOT_QUARANTINED == error)
    {
        //dbg msg
        logMsg(LOG_DEBUG, [NSString stringWithFormat:@"%@ is *not* quarantined (QTN_NOT_QUARANTINED)", path]);
        
        //bail
        goto bail;
    }
    
    //get flags
    flags = qtn_file_get_flags_FP(quarantineFile);
    
    //dbg msg
    logMsg(LOG_DEBUG, [NSString stringWithFormat:@"quarantine flags: %#x", flags]);

bail:
    
    //cleanup
    if(NULL != quarantineFile)
    {
        //free
        qtn_file_free_FP(quarantineFile);
        quarantineFile = NULL;
    }

    return flags;
}

#endif
