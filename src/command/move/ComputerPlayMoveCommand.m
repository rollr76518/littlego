// -----------------------------------------------------------------------------
// Copyright 2011-2012 Patrick Näf (herzbube@herzbube.ch)
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
// -----------------------------------------------------------------------------


// Project includes
#import "ComputerPlayMoveCommand.h"
#import "../backup/BackupGameCommand.h"
#import "../backup/CleanBackupCommand.h"
#import "../game/NewGameCommand.h"
#import "../game/SaveGameCommand.h"
#import "../../archive/ArchiveViewModel.h"
#import "../../go/GoBoard.h"
#import "../../go/GoGame.h"
#import "../../go/GoPlayer.h"
#import "../../go/GoPoint.h"
#import "../../go/GoVertex.h"
#import "../../gtp/GtpCommand.h"
#import "../../gtp/GtpResponse.h"
#import "../../main/ApplicationDelegate.h"


// -----------------------------------------------------------------------------
/// @brief Class extension with private methods for ComputerPlayMoveCommand.
// -----------------------------------------------------------------------------
@interface ComputerPlayMoveCommand()
/// @name Initialization and deallocation
//@{
- (void) dealloc;
//@}
/// @name GTP response handlers
//@{
- (void) gtpResponseReceived:(GtpResponse*)response;
//@}
/// @name UIAlertViewDelegate protocol
//@{
- (void) alertView:(UIAlertView*)alertView didDismissWithButtonIndex:(NSInteger)buttonIndex;
//@}
/// @name SendBugReportControllerDelegate protocol
//@{
- (void) sendBugReportDidFinish:(SendBugReportController*)sendBugReportController;
//@}
/// @name Helpers
//@{
- (void) handleComputerPlayedIllegalMove1;
- (void) handleComputerPlayedIllegalMove2;
- (void) sendBugReport;
- (void) startNewGame;
//@}
/// @name Private properties
//@{
@property(nonatomic, retain) GoPoint* illegalMove;
//@}
@end


@implementation ComputerPlayMoveCommand

// -----------------------------------------------------------------------------
/// @brief Initializes a ComputerPlayMoveCommand.
///
/// @note This is the designated initializer of ComputerPlayMoveCommand.
// -----------------------------------------------------------------------------
- (id) init
{
  // Call designated initializer of superclass (CommandBase)
  self = [super init];
  if (! self)
    return nil;

  GoGame* sharedGame = [GoGame sharedGame];
  assert(sharedGame);
  if (! sharedGame)
  {
    DDLogError(@"%@: GoGame object is nil", [self shortDescription]);
    [self release];
    return nil;
  }
  enum GoGameState gameState = sharedGame.state;
  assert(GoGameStateGameHasEnded != gameState);
  if (GoGameStateGameHasEnded == gameState)
  {
    DDLogError(@"%@: Unexpected game state %d", [self shortDescription], gameState);
    [self release];
    return nil;
  }

  self.game = sharedGame;
  self.illegalMove = nil;

  return self;
}

// -----------------------------------------------------------------------------
/// @brief Deallocates memory allocated by this ComputerPlayMoveCommand object.
// -----------------------------------------------------------------------------
- (void) dealloc
{
  self.game = nil;
  self.illegalMove = nil;
  [super dealloc];
}

// -----------------------------------------------------------------------------
/// @brief Executes this command. See the class documentation for details.
// -----------------------------------------------------------------------------
- (bool) doIt
{
  NSString* commandString = @"genmove ";
  commandString = [commandString stringByAppendingString:self.game.currentPlayer.colorString];
  GtpCommand* command = [GtpCommand command:commandString
                             responseTarget:self
                                   selector:@selector(gtpResponseReceived:)];
  [command submit];

  // Thinking state must change after any of the other things; this order is
  // important for observer notifications
  self.game.computerThinks = true;

  return true;
}

// -----------------------------------------------------------------------------
/// @brief Is triggered when the GTP engine responds to the command submitted
/// in doIt().
// -----------------------------------------------------------------------------
- (void) gtpResponseReceived:(GtpResponse*)response
{
  if (! response.status)
  {
    assert(0);
    return;
  }

  NSString* responseString = [response.parsedResponse lowercaseString];
  if ([responseString isEqualToString:@"pass"])
    [self.game pass];
  else if ([responseString isEqualToString:@"resign"])
    [self.game resign];
  else
  {
    GoPoint* point = [self.game.board pointAtVertex:responseString];
    if (point)
    {
      // TODO: Remove this check, and handleComputerPlayedIllegalMove1/2
      // methods, as soon as issue 90 on GitHub has been fixed.
      if ([self.game isLegalMove:point])
      {
        [self.game play:point];
      }
      else
      {
        self.illegalMove = point;
        [self handleComputerPlayedIllegalMove1];
        return;
      }
    }
    else
    {
      DDLogError(@"%@: Invalid vertex %@", [self shortDescription], responseString);
      assert(0);
      return;
    }
  }

  [[[[BackupGameCommand alloc] init] autorelease] submit];

  bool computerGoesOnPlaying = false;
  switch (self.game.state)
  {
    case GoGameStateGameIsPaused:  // game has been paused while GTP was thinking about its last move
    case GoGameStateGameHasEnded:  // game has ended as a result of the last move (e.g. resign, 2x pass)
      break;
    default:
      if ([self.game isComputerPlayersTurn])
        computerGoesOnPlaying = true;
      break;
  }

  if (computerGoesOnPlaying)
  {
    [[[[ComputerPlayMoveCommand alloc] init] autorelease] submit];
  }
  else
  {
    // Thinking state must change after any of the other things; this order is
    // important for observer notifications.
    self.game.computerThinks = false;
  }
}

// -----------------------------------------------------------------------------
/// @brief Is invoked when the GTP engine plays a move that Little Go thinks
/// is illegal. Part 1: Offers the user a chance to submit a bug report before
/// the app crashes.
///
/// This method has been added to gather information in order to fix issue 90
/// on GitHub. This method can be removed as soon the issue has been fixed.
// -----------------------------------------------------------------------------
- (void) handleComputerPlayedIllegalMove1
{
  NSString* message = @"The computer played an illegal move. This is almost certainly a bug in Little Go. Would you like to report this incident now so that we can fix the bug?"; 
  UIAlertView* alert = [[UIAlertView alloc] initWithTitle:@"Unexpected error"
                                                  message:message
                                                 delegate:self
                                        cancelButtonTitle:@"No"
                                        otherButtonTitles:@"Yes", nil];
  alert.tag = AlertViewTypeComputerPlayedIllegalMove;
  [alert show];

  [self retain];  // must survive until the delegate method is invoked
}

// -----------------------------------------------------------------------------
/// @brief Is invoked when the GTP engine plays a move that Little Go thinks
/// is illegal. Part 2: Saves the game in progress and informs the user that a
/// new game needs to be started.
///
/// This method has been added to gather information in order to fix issue 90
/// on GitHub. This method can be removed as soon the issue has been fixed.
// -----------------------------------------------------------------------------
- (void) handleComputerPlayedIllegalMove2;
{
  ArchiveViewModel* model = [ApplicationDelegate sharedDelegate].archiveViewModel;
  NSString* defaultGameName = [model defaultGameName:[GoGame sharedGame]];
  [[[[SaveGameCommand alloc] initWithSaveGame:defaultGameName] autorelease] submit];

  NSString* messageFormat = @"Until this bug is fixed, Little Go unfortunately cannot continue with the game in progress. The game has been saved to the archive under the name\n\n%@\n\nA new game is being started now to bring the app back into a good state.";
  NSString* message = [NSString stringWithFormat:messageFormat, defaultGameName];
  UIAlertView* alert = [[UIAlertView alloc] initWithTitle:@"New game about to begin"
                                                  message:message
                                                 delegate:self
                                        cancelButtonTitle:nil
                                        otherButtonTitles:@"Ok", nil];
  alert.tag = AlertViewTypeNewGameAfterComputerPlayedIllegalMove;
  [alert show];

  [self retain];  // must survive until the delegate method is invoked
}

// -----------------------------------------------------------------------------
/// @brief Reacts to the user dismissing an alert view for which this controller
/// is the delegate.
///
/// This method has been added to gather information in order to fix issue 90
/// on GitHub. This method can be removed as soon the issue has been fixed.
// -----------------------------------------------------------------------------
- (void) alertView:(UIAlertView*)alertView didDismissWithButtonIndex:(NSInteger)buttonIndex
{
  [self autorelease];  // balance retain that is sent before an alert is shown

  switch (alertView.tag)
  {
    case AlertViewTypeComputerPlayedIllegalMove:
    {
      switch (buttonIndex)
      {
        case AlertViewButtonTypeNo:
          [self handleComputerPlayedIllegalMove2];
          break;
        case AlertViewButtonTypeYes:
          [self sendBugReport];
          break;
        default:
          break;
      }
      break;
    }
    case AlertViewTypeNewGameAfterComputerPlayedIllegalMove:
    {
      [self startNewGame];
      break;
    }
  }
}

// -----------------------------------------------------------------------------
/// @brief Triggers the sending of a bug report.
///
/// This method has been added to gather information in order to fix issue 90
/// on GitHub. This method can be removed as soon the issue has been fixed.
// -----------------------------------------------------------------------------
- (void) sendBugReport
{
  // Use the view controller that is currently selected - this may not
  // always be the Play view controller, e.g. if the user has switched to
  // another tab while the computer was thinking
  ApplicationDelegate* appDelegate = [ApplicationDelegate sharedDelegate];
  UIViewController* modalViewControllerParent = appDelegate.tabBarController.selectedViewController;
  SendBugReportController* controller = [SendBugReportController controller];
  controller.delegate = self;
  controller.bugReportDescription = [NSString stringWithFormat:@"Little Go claims that the computer player made an illegal move by playing on intersection %@.", self.illegalMove.vertex.string];
  [controller sendBugReport:modalViewControllerParent];
  [self retain];  // must survive until the delegate method is invoked
}

// -----------------------------------------------------------------------------
/// @brief SendBugReportControllerDelegate method
///
/// This method has been added to gather information in order to fix issue 90
/// on GitHub. This method can be removed as soon the issue has been fixed.
// -----------------------------------------------------------------------------
- (void) sendBugReportDidFinish:(SendBugReportController*)sendBugReportController
{
  [self autorelease];  // balance retain that is sent before bug report controller runs
  [self handleComputerPlayedIllegalMove2];
}

// -----------------------------------------------------------------------------
/// @brief Triggers the sending of a bug report.
///
/// This method has been added to gather information in order to fix issue 90
/// on GitHub. This method can be removed as soon the issue has been fixed.
// -----------------------------------------------------------------------------
- (void) startNewGame
{
  [[[[CleanBackupCommand alloc] init] autorelease] submit];
  [[[[NewGameCommand alloc] init] autorelease] submit];
}

@end
