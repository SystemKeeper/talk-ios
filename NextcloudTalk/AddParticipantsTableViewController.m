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

#import "AddParticipantsTableViewController.h"

#import "NCAPIController.h"
#import "NCAppBranding.h"
#import "NCUserInterfaceController.h"
#import "NCUtils.h"
#import "PlaceholderView.h"
#import "ResultMultiSelectionTableViewController.h"
#import "UIImageView+AFNetworking.h"

@interface AddParticipantsTableViewController () <UISearchBarDelegate, UISearchControllerDelegate, UISearchResultsUpdating>
{
    NSMutableDictionary *_participants;
    NSArray *_indexes;
    NCRoom *_room;
    NSArray *_participantsInRoom;
    UISearchController *_searchController;
    ResultMultiSelectionTableViewController *_resultTableViewController;
    NSMutableArray *_selectedParticipants;
    PlaceholderView *_participantsBackgroundView;
    NSTimer *_searchTimer;
    NSURLSessionTask *_searchParticipantsTask;
}
@end

@implementation AddParticipantsTableViewController

- (instancetype)initForRoom:(NCRoom *)room
{
    self = [super init];
    if (!self) {
        return nil;
    }
    
    _room = room;
    _participantsInRoom = [room.participants valueForKey:@"self"];
    _participants = [[NSMutableDictionary alloc] init];
    _indexes = [[NSArray alloc] init];
    _selectedParticipants = [[NSMutableArray alloc] init];
    
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    [self.tableView registerNib:[UINib nibWithNibName:kContactsTableCellNibName bundle:nil] forCellReuseIdentifier:kContactCellIdentifier];
    self.tableView.separatorInset = UIEdgeInsetsMake(0, 72, 0, 0);
    self.tableView.sectionIndexBackgroundColor = [UIColor clearColor];
    
    _resultTableViewController = [[ResultMultiSelectionTableViewController alloc] init];
    _searchController = [[UISearchController alloc] initWithSearchResultsController:_resultTableViewController];
    _searchController.searchResultsUpdater = self;
    [_searchController.searchBar sizeToFit];
    
    if (@available(iOS 13.0, *)) {
        UIColor *themeColor = [NCAppBranding themeColor];
        UINavigationBarAppearance *appearance = [[UINavigationBarAppearance alloc] init];
        [appearance configureWithOpaqueBackground];
        appearance.backgroundColor = themeColor;
        appearance.titleTextAttributes = @{NSForegroundColorAttributeName:[NCAppBranding themeTextColor]};
        self.navigationItem.standardAppearance = appearance;
        self.navigationItem.compactAppearance = appearance;
        self.navigationItem.scrollEdgeAppearance = appearance;
        
        self.navigationItem.searchController = _searchController;
        self.navigationItem.searchController.searchBar.searchTextField.backgroundColor = [NCUtils searchbarBGColorForColor:themeColor];
        _searchController.searchBar.tintColor = [NCAppBranding themeTextColor];
        UITextField *searchTextField = [_searchController.searchBar valueForKey:@"searchField"];
        UIButton *clearButton = [searchTextField valueForKey:@"_clearButton"];
        searchTextField.tintColor = [NCAppBranding themeTextColor];
        searchTextField.textColor = [NCAppBranding themeTextColor];
        dispatch_async(dispatch_get_main_queue(), ^{
            // Search bar placeholder
            searchTextField.attributedPlaceholder = [[NSAttributedString alloc] initWithString:NSLocalizedString(@"Search", nil)
            attributes:@{NSForegroundColorAttributeName:[[NCAppBranding themeTextColor] colorWithAlphaComponent:0.5]}];
            // Search bar search icon
            UIImageView *searchImageView = (UIImageView *)searchTextField.leftView;
            searchImageView.image = [searchImageView.image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
            [searchImageView setTintColor:[[NCAppBranding themeTextColor] colorWithAlphaComponent:0.5]];
            // Search bar search clear button
            UIImage *clearButtonImage = [clearButton.imageView.image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
            [clearButton setImage:clearButtonImage forState:UIControlStateNormal];
            [clearButton setImage:clearButtonImage forState:UIControlStateHighlighted];
            [clearButton setTintColor:[NCAppBranding themeTextColor]];
        });
    } else if (@available(iOS 11.0, *)) {
        self.navigationItem.searchController = _searchController;
        _searchController.searchBar.tintColor = [NCAppBranding themeTextColor];
        UITextField *searchTextField = [_searchController.searchBar valueForKey:@"searchField"];
        searchTextField.tintColor = [NCAppBranding themeColor];
        UIView *backgroundview = [searchTextField.subviews firstObject];
        backgroundview.backgroundColor = [UIColor whiteColor];
        backgroundview.layer.cornerRadius = 8;
        backgroundview.clipsToBounds = YES;
    } else {
        self.tableView.tableHeaderView = _searchController.searchBar;
        _searchController.searchBar.barTintColor = [UIColor colorWithRed:0.94 green:0.94 blue:0.96 alpha:1.0]; //efeff4
        _searchController.searchBar.layer.borderWidth = 1;
        _searchController.searchBar.layer.borderColor = [[UIColor colorWithRed:0.94 green:0.94 blue:0.96 alpha:1.0] CGColor];
    }
    
    self.tableView.tableFooterView = [[UIView alloc] initWithFrame:CGRectZero];
    // Contacts placeholder view
    _participantsBackgroundView = [[PlaceholderView alloc] init];
    [_participantsBackgroundView.placeholderImage setImage:[UIImage imageNamed:@"contacts-placeholder"]];
    [_participantsBackgroundView.placeholderText setText:NSLocalizedString(@"No participants found", nil)];
    [_participantsBackgroundView.placeholderView setHidden:YES];
    [_participantsBackgroundView.loadingView startAnimating];
    self.tableView.backgroundView = _participantsBackgroundView;
    
    // We want ourselves to be the delegate for the result table so didSelectRowAtIndexPath is called for both tables.
    _resultTableViewController.tableView.delegate = self;
    _searchController.delegate = self;
    _searchController.searchBar.delegate = self;
    _searchController.hidesNavigationBarDuringPresentation = NO;

    
    self.definesPresentationContext = YES;
    
    UIBarButtonItem *cancelButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                                                  target:self action:@selector(cancelButtonPressed)];
    self.navigationController.navigationBar.topItem.leftBarButtonItem = cancelButton;
    self.navigationItem.title = NSLocalizedString(@"Add participants", nil);
    [self.navigationController.navigationBar setTitleTextAttributes:
     @{NSForegroundColorAttributeName:[NCAppBranding themeTextColor]}];
    self.navigationController.navigationBar.tintColor = [NCAppBranding themeTextColor];
    self.navigationController.navigationBar.translucent = NO;
    self.navigationController.navigationBar.barTintColor = [NCAppBranding themeColor];
    
    // Fix uisearchcontroller animation
    self.extendedLayoutIncludesOpaqueBars = YES;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    
    if (@available(iOS 11.0, *)) {
        self.navigationItem.hidesSearchBarWhenScrolling = NO;
    }
    
    [self getPossibleParticipants];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    
    if (@available(iOS 11.0, *)) {
        self.navigationItem.hidesSearchBarWhenScrolling = NO;
    }
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
}

#pragma mark - View controller actions

- (void)cancelButtonPressed
{
    [self close];
}

- (void)close
{
    [self.delegate addParticipantsTableViewControllerDidFinish:self];
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

- (void)addButtonPressed
{
    self.tableView.allowsSelection = NO;
    _resultTableViewController.tableView.allowsSelection = NO;
    
    for (NCUser *participant in _selectedParticipants) {
        [self addParticipantToRoom:participant];
    }
    
    [self close];
}

- (void)addParticipantToRoom:(NCUser *)participant
{
    [[NCAPIController sharedInstance] addParticipant:participant.userId ofType:participant.source toRoom:_room.token forAccount:[[NCDatabaseManager sharedInstance] activeAccount] withCompletionBlock:^(NSError *error) {
        if (error) {
            UIAlertController * alert = [UIAlertController
                                         alertControllerWithTitle:NSLocalizedString(@"Could not add participant", nil)
                                         message:[NSString stringWithFormat:NSLocalizedString(@"An error occurred while adding %@ to the room", nil), participant.name]
                                         preferredStyle:UIAlertControllerStyleAlert];
            
            UIAlertAction* okButton = [UIAlertAction
                                       actionWithTitle:NSLocalizedString(@"OK", nil)
                                       style:UIAlertActionStyleDefault
                                       handler:nil];
            
            [alert addAction:okButton];
            
            [[NCUserInterfaceController sharedInstance] presentAlertViewController:alert];
        }
    }];
}

- (void)updateCounter
{
    if (_selectedParticipants.count > 0) {
        UIBarButtonItem *addButton = [[UIBarButtonItem alloc] initWithTitle:[NSString stringWithFormat:NSLocalizedString(@"Add (%lu)", nil), (unsigned long)_selectedParticipants.count]
                                                                      style:UIBarButtonItemStylePlain target:self action:@selector(addButtonPressed)];
        self.navigationController.navigationBar.topItem.rightBarButtonItem = addButton;
    } else {
        self.navigationController.navigationBar.topItem.rightBarButtonItem = nil;
    }
}

#pragma mark - Participants actions

- (NSMutableArray *)filterContacts:(NSMutableArray *)contacts
{
    NSMutableArray *participants = [[NSMutableArray alloc] init];
    for (NCUser *user in contacts) {
        if (![_participantsInRoom containsObject:user.userId]) {
            [participants addObject:user];
        } else if (![user.source isEqualToString:kParticipantTypeUser]) {
            [participants addObject:user];
        }
    }
    return participants;
}

- (void)getPossibleParticipants
{
    [[NCAPIController sharedInstance] getContactsForAccount:[[NCDatabaseManager sharedInstance] activeAccount] forRoom:_room.token groupRoom:YES withSearchParam:nil andCompletionBlock:^(NSArray *indexes, NSMutableDictionary *contacts, NSMutableArray *contactList, NSError *error) {
        if (!error) {
            NSMutableArray *filteredParticipants = [self filterContacts:contactList];
            NSMutableDictionary *participants = [[NCAPIController sharedInstance] indexedUsersFromUsersArray:filteredParticipants];
            _participants = participants;
            _indexes = [[participants allKeys] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
            [_participantsBackgroundView.loadingView stopAnimating];
            [_participantsBackgroundView.loadingView setHidden:YES];
            [_participantsBackgroundView.placeholderView setHidden:(participants.count > 0)];
            [self.tableView reloadData];
        } else {
            NSLog(@"Error while trying to get participants: %@", error);
        }
    }];
}

- (void)searchForParticipantsWithString:(NSString *)searchString
{
    [_searchParticipantsTask cancel];
    _searchParticipantsTask = [[NCAPIController sharedInstance] getContactsForAccount:[[NCDatabaseManager sharedInstance] activeAccount] forRoom:_room.token groupRoom:YES withSearchParam:searchString andCompletionBlock:^(NSArray *indexes, NSMutableDictionary *contacts, NSMutableArray *contactList, NSError *error) {
        if (!error) {
            NSMutableArray *filteredParticipants = [self filterContacts:contactList];
            NSMutableDictionary *participants = [[NCAPIController sharedInstance] indexedUsersFromUsersArray:filteredParticipants];
            NSArray *sortedIndexes = [[participants allKeys] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
            [_resultTableViewController setSearchResultContacts:participants withIndexes:sortedIndexes];
        } else {
            if (error.code != -999) {
                NSLog(@"Error while searching for participants: %@", error);
            }
        }
    }];
}

- (BOOL)isParticipantAlreadySelected:(NCUser *)participant
{
    for (NCUser *user in _selectedParticipants) {
        if ([user.userId isEqualToString:participant.userId] &&
            [user.source isEqualToString:participant.source]) {
            return YES;
        }
    }
    return NO;
}

- (void)removeSelectedParticipant:(NCUser *)participant
{
    NCUser *userToDelete = nil;
    for (NCUser *user in _selectedParticipants) {
        if ([user.userId isEqualToString:participant.userId] &&
            [user.source isEqualToString:participant.source]) {
            userToDelete = user;
        }
    }
    
    if (userToDelete) {
        [_selectedParticipants removeObject:userToDelete];
    }
}

#pragma mark - Search controller

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController
{
    [_searchTimer invalidate];
    _searchTimer = nil;
    [_resultTableViewController showSearchingUI];
    dispatch_async(dispatch_get_main_queue(), ^{
        _searchTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(searchForParticipants) userInfo:nil repeats:NO];
    });
}

- (void)searchForParticipants
{
    NSString *searchString = _searchController.searchBar.text;
    if (![searchString isEqualToString:@""]) {
        [self searchForParticipantsWithString:searchString];
    }
}

- (void)didDismissSearchController:(UISearchController *)searchController
{
    [self.tableView reloadData];
}

#pragma mark - Table view data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return _indexes.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    NSString *index = [_indexes objectAtIndex:section];
    NSArray *participants = [_participants objectForKey:index];
    return participants.count;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return kContactsTableCellHeight;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    return [_indexes objectAtIndex:section];
}

- (NSArray *)sectionIndexTitlesForTableView:(UITableView *)tableView
{
    return _indexes;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    NSString *index = [_indexes objectAtIndex:indexPath.section];
    NSArray *participants = [_participants objectForKey:index];
    NCUser *participant = [participants objectAtIndex:indexPath.row];
    ContactsTableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kContactCellIdentifier forIndexPath:indexPath];
    if (!cell) {
        cell = [[ContactsTableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:kContactCellIdentifier];
    }
    
    cell.labelTitle.text = participant.name;
    
    if ([participant.source isEqualToString:kParticipantTypeUser]) {
        [cell.contactImage setImageWithURLRequest:[[NCAPIController sharedInstance] createAvatarRequestForUser:participant.userId andSize:96 usingAccount:[[NCDatabaseManager sharedInstance] activeAccount]]
                                 placeholderImage:nil success:nil failure:nil];
    } else if ([participant.source isEqualToString:kParticipantTypeEmail]) {
        [cell.contactImage setImage:[UIImage imageNamed:@"mail-bg"]];
    } else {
        [cell.contactImage setImage:[UIImage imageNamed:@"group-bg"]];
    }
    
    UIImageView *checkboxChecked = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"checkbox-checked"]];
    UIImageView *checkboxUnchecked = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"checkbox-unchecked"]];
    cell.accessoryView = ([self isParticipantAlreadySelected:participant]) ? checkboxChecked : checkboxUnchecked;
    
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    NSString *index = nil;
    NSArray *participants = nil;
    
    if (_searchController.active) {
        index = [_resultTableViewController.indexes objectAtIndex:indexPath.section];
        participants = [_resultTableViewController.contacts objectForKey:index];
    } else {
        index = [_indexes objectAtIndex:indexPath.section];
        participants = [_participants objectForKey:index];
    }
    
    NCUser *participant = [participants objectAtIndex:indexPath.row];
    if (![self isParticipantAlreadySelected:participant]) {
        [_selectedParticipants addObject:participant];
    } else {
        [self removeSelectedParticipant:participant];
    }
    
    _resultTableViewController.selectedParticipants = _selectedParticipants;
    
    [tableView beginUpdates];
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
    [tableView endUpdates];
    
    [self updateCounter];
}

@end
