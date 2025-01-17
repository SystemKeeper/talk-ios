/**
 * @copyright Copyright (c) 2020 Ivan Sein <ivan@nextcloud.com>
 *
 * @author Ivan Sein <ivan@nextcloud.com>
 *
 * @license GNU GPL version 3 or any later version
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 */

#import "NotificationService.h"

#import "NCAPIController.h"
#import "NCAppBranding.h"
#import "NCDatabaseManager.h"
#import "NCNotification.h"
#import "NCPushNotification.h"
#import "NCSettingsController.h"

@interface NotificationService ()

@property (nonatomic, strong) void (^contentHandler)(UNNotificationContent *contentToDeliver);
@property (nonatomic, strong) UNMutableNotificationContent *bestAttemptContent;

@end

@implementation NotificationService

- (void)didReceiveNotificationRequest:(UNNotificationRequest *)request withContentHandler:(void (^)(UNNotificationContent * _Nonnull))contentHandler {
    self.contentHandler = contentHandler;
    self.bestAttemptContent = [request.content mutableCopy];
    
    self.bestAttemptContent.title = @"";
    self.bestAttemptContent.body = NSLocalizedString(@"You received a new notification", nil);
    
    // Configure database
    NSString *path = [[[[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:groupIdentifier] URLByAppendingPathComponent:kTalkDatabaseFolder] path];
    RLMRealmConfiguration *configuration = [RLMRealmConfiguration defaultConfiguration];
    NSURL *databaseURL = [[NSURL fileURLWithPath:path] URLByAppendingPathComponent:kTalkDatabaseFileName];
    configuration.fileURL = databaseURL;
    configuration.schemaVersion= kTalkDatabaseSchemaVersion;
    configuration.objectClasses = @[TalkAccount.class];
    NSError *error = nil;
    RLMRealm *realm = [RLMRealm realmWithConfiguration:configuration error:&error];
    
    // Decrypt message
    NSString *message = [self.bestAttemptContent.userInfo objectForKey:@"subject"];
    for (TalkAccount *talkAccount in [TalkAccount allObjectsInRealm:realm]) {
        TalkAccount *account = [[TalkAccount alloc] initWithValue:talkAccount];
        NSData *pushNotificationPrivateKey = [[NCSettingsController sharedInstance] pushNotificationPrivateKeyForAccountId:account.accountId];
        if (message && pushNotificationPrivateKey) {
            @try {
                NSString *decryptedMessage = [[NCSettingsController sharedInstance] decryptPushNotification:message withDevicePrivateKey:pushNotificationPrivateKey];
                if (decryptedMessage) {
                    NCPushNotification *pushNotification = [NCPushNotification pushNotificationFromDecryptedString:decryptedMessage withAccountId:account.accountId];
                    
                    // Update unread notifications counter for push notification account
                    [realm beginWriteTransaction];
                    NSPredicate *query = [NSPredicate predicateWithFormat:@"accountId = %@", account.accountId];
                    TalkAccount *managedAccount = [TalkAccount objectsWithPredicate:query].firstObject;
                    managedAccount.unreadBadgeNumber += 1;
                    managedAccount.unreadNotification = (managedAccount.active) ? NO : YES;
                    [realm commitWriteTransaction];
                    
                    // Get the total number of unread notifications
                    NSInteger unreadNotifications = 0;
                    for (TalkAccount *user in [TalkAccount allObjectsInRealm:realm]) {
                        unreadNotifications += user.unreadBadgeNumber;
                    }
                    
                    self.bestAttemptContent.body = pushNotification.bodyForRemoteAlerts;
                    self.bestAttemptContent.threadIdentifier = pushNotification.roomToken;
                    self.bestAttemptContent.sound = [UNNotificationSound defaultSound];
                    self.bestAttemptContent.badge = @(unreadNotifications);
                    NSMutableDictionary *userInfo = [[NSMutableDictionary alloc] init];
                    [userInfo setObject:pushNotification.jsonString forKey:@"pushNotification"];
                    [userInfo setObject:pushNotification.accountId forKey:@"accountId"];
                    self.bestAttemptContent.userInfo = userInfo;
                    // Create title and body structure if there is a new line in the subject
                    NSArray* components = [pushNotification.subject componentsSeparatedByString:@"\n"];
                    if (components.count > 1) {
                        NSString *title = [components objectAtIndex:0];
                        NSMutableArray *mutableComponents = [[NSMutableArray alloc] initWithArray:components];
                        [mutableComponents removeObjectAtIndex:0];
                        NSString *body = [mutableComponents componentsJoinedByString:@"\n"];
                        self.bestAttemptContent.title = title;
                        self.bestAttemptContent.body = body;
                    }
                    // Try to get the notification from the server
                    [[NCAPIController sharedInstance] getServerNotification:pushNotification.notificationId forAccount:account withCompletionBlock:^(NSDictionary *notification, NSError *error, NSInteger statusCode) {
                        if (!error) {
                            NCNotification *serverNotification = [NCNotification notificationWithDictionary:notification];
                            if (serverNotification && serverNotification.notificationType == kNCNotificationTypeChat) {
                                self.bestAttemptContent.title = serverNotification.chatMessageTitle;
                                self.bestAttemptContent.body = serverNotification.message;
                                if (@available(iOS 12.0, *)) {
                                    self.bestAttemptContent.summaryArgument = serverNotification.chatMessageAuthor;
                                }
                            }
                        }
                        self.contentHandler(self.bestAttemptContent);
                    }];
                }
            } @catch (NSException *exception) {
                continue;
                NSLog(@"An error ocurred decrypting the message. %@", exception);
            }
        }
    }
}

- (void)serviceExtensionTimeWillExpire {
    // Called just before the extension will be terminated by the system.
    // Use this as an opportunity to deliver your "best attempt" at modified content, otherwise the original push payload will be used.
    self.bestAttemptContent.title = @"";
    self.bestAttemptContent.body = NSLocalizedString(@"You received a new notification", nil);
    
    self.contentHandler(self.bestAttemptContent);
}

@end
