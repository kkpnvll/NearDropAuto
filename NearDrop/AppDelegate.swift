//
//  AppDelegate.swift
//  NearDrop
//
//  Created by Grishka on 08.04.2023.
//

import Cocoa
import UserNotifications
import NearbyShare
import ServiceManagement

@main
class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, MainAppDelegate{
	private var statusItem:NSStatusItem?
	private var activeIncomingTransfers:[String:TransferInfo]=[:]
	private static let autoAcceptKey = "autoAcceptFiles"
	private var autoAcceptMenuItem:NSMenuItem?
	private var launchAtLoginMenuItem:NSMenuItem?

    func applicationDidFinishLaunching(_ aNotification: Notification) {
		let menu=NSMenu()
		menu.addItem(withTitle: NSLocalizedString("VisibleToEveryone", value: "Visible to everyone", comment: ""), action: nil, keyEquivalent: "")
		menu.addItem(withTitle: String(format: NSLocalizedString("DeviceName", value: "Device name: %@", comment: ""), arguments: [Host.current().localizedName!]), action: nil, keyEquivalent: "")
		menu.addItem(NSMenuItem.separator())
		
		let autoAcceptItem = NSMenuItem(title: NSLocalizedString("AutoAccept", value: "Auto-accept files", comment: ""), action: #selector(toggleAutoAccept(_:)), keyEquivalent: "")
		autoAcceptItem.target = self
		autoAcceptItem.state = UserDefaults.standard.bool(forKey: AppDelegate.autoAcceptKey) ? .on : .off
		autoAcceptMenuItem = autoAcceptItem
		menu.addItem(autoAcceptItem)
		
		let launchAtLoginItem = NSMenuItem(title: NSLocalizedString("LaunchAtLogin", value: "Launch at login", comment: ""), action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
		launchAtLoginItem.target = self
		launchAtLoginItem.state = isLaunchAtLoginEnabled() ? .on : .off
		launchAtLoginMenuItem = launchAtLoginItem
		menu.addItem(launchAtLoginItem)
		
		menu.addItem(NSMenuItem.separator())
		menu.addItem(withTitle: NSLocalizedString("Quit", value: "Quit QuickSend", comment: ""), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
		statusItem=NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
		statusItem?.button?.image=NSImage(named: "MenuBarIcon")
		statusItem?.menu=menu
		statusItem?.behavior = .removalAllowed
		
		let nc=UNUserNotificationCenter.current()
		nc.requestAuthorization(options: [.alert, .sound]) { granted, err in
			if !granted{
				DispatchQueue.main.async {
					self.showNotificationsDeniedAlert()
				}
			}
		}
		nc.delegate=self
		let incomingTransfersCategory=UNNotificationCategory(identifier: "INCOMING_TRANSFERS", actions: [
			UNNotificationAction(identifier: "ACCEPT", title: NSLocalizedString("Accept", comment: ""), options: UNNotificationActionOptions.authenticationRequired),
			UNNotificationAction(identifier: "DECLINE", title: NSLocalizedString("Decline", comment: ""))
		], intentIdentifiers: [], options: [.customDismissAction])
		let errorsCategory=UNNotificationCategory(identifier: "ERRORS", actions: [], intentIdentifiers: [])
		nc.setNotificationCategories([incomingTransfersCategory, errorsCategory])
		NearbyConnectionManager.shared.mainAppDelegate=self
		NearbyConnectionManager.shared.becomeVisible()
	}
	
	func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
		statusItem?.isVisible=true
		return true
	}

    func applicationWillTerminate(_ aNotification: Notification) {
		UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
	
	@objc func toggleAutoAccept(_ sender: NSMenuItem) {
		let newValue = !UserDefaults.standard.bool(forKey: AppDelegate.autoAcceptKey)
		UserDefaults.standard.set(newValue, forKey: AppDelegate.autoAcceptKey)
		sender.state = newValue ? .on : .off
	}
	
	@objc func toggleLaunchAtLogin(_ sender: NSMenuItem) {
		if #available(macOS 13.0, *) {
			let service = SMAppService.mainApp
			let isEnabled = service.status == .enabled
			
			do {
				if isEnabled {
					try service.unregister()
					sender.state = .off
				} else {
					try service.register()
					sender.state = .on
				}
			} catch {
				print("Failed to \(isEnabled ? "unregister" : "register") launch at login: \(error.localizedDescription)")
				let alert = NSAlert()
				alert.messageText = NSLocalizedString("LaunchAtLoginError", value: "Launch at Login Error", comment: "")
				alert.informativeText = error.localizedDescription
				alert.alertStyle = .warning
				alert.runModal()
			}
		} else {
			// For macOS 12 and earlier, show a message that this feature requires macOS 13+
			let alert = NSAlert()
			alert.messageText = NSLocalizedString("LaunchAtLoginUnsupported", value: "Feature Not Available", comment: "")
			alert.informativeText = NSLocalizedString("LaunchAtLoginUnsupportedMessage", value: "Launch at login requires macOS 13 or later.", comment: "")
			alert.alertStyle = .informational
			alert.runModal()
		}
	}
	
	private func isLaunchAtLoginEnabled() -> Bool {
		if #available(macOS 13.0, *) {
			return SMAppService.mainApp.status == .enabled
		}
		return false
	}
	
	func showNotificationsDeniedAlert(){
		let alert=NSAlert()
		alert.alertStyle = .critical
		alert.messageText=NSLocalizedString("NotificationsDenied.Title", value: "Notification Permission Required", comment: "")
		alert.informativeText=NSLocalizedString("NotificationsDenied.Message", value: "NearDrop needs to be able to display notifications for incoming file transfers. Please allow notifications in System Settings.", comment: "")
		alert.addButton(withTitle: NSLocalizedString("NotificationsDenied.OpenSettings", value: "Open settings", comment: ""))
		alert.addButton(withTitle: NSLocalizedString("Quit", value: "Quit QuickSend", comment: ""))
		let result=alert.runModal()
		if result==NSApplication.ModalResponse.alertFirstButtonReturn{
			NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!)
		}else if result==NSApplication.ModalResponse.alertSecondButtonReturn{
			NSApplication.shared.terminate(nil)
		}
	}
	
	func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
		let transferID=response.notification.request.content.userInfo["transferID"]! as! String
		NearbyConnectionManager.shared.submitUserConsent(transferID: transferID, accept: response.actionIdentifier=="ACCEPT")
		if response.actionIdentifier != "ACCEPT"{
			activeIncomingTransfers.removeValue(forKey: transferID)
		}
		completionHandler()
	}
	
	func obtainUserConsent(for transfer: TransferMetadata, from device: RemoteDeviceInfo) {
		let fileStr:String
		if let textTitle=transfer.textDescription{
			fileStr=textTitle
		}else if transfer.files.count==1{
			fileStr=transfer.files[0].name
		}else{
			fileStr=String.localizedStringWithFormat(NSLocalizedString("NFiles", value: "%d files", comment: ""), transfer.files.count)
		}
		
		let autoAccept = UserDefaults.standard.bool(forKey: AppDelegate.autoAcceptKey)
		
		if autoAccept {
			// Auto-accept the transfer
			NearbyConnectionManager.shared.submitUserConsent(transferID: transfer.id, accept: true)
			self.activeIncomingTransfers[transfer.id]=TransferInfo(device: device, transfer: transfer)
			
			// Show an informational notification (without action buttons)
			let notificationContent=UNMutableNotificationContent()
			notificationContent.title="NearDrop"
			notificationContent.subtitle=String(format:NSLocalizedString("PinCode", value: "PIN: %@", comment: ""), arguments: [transfer.pinCode!])
			notificationContent.body=String(format: NSLocalizedString("ReceivingFiles", value: "Receiving %1$@ from %2$@", comment: ""), arguments: [fileStr, device.name])
			notificationContent.sound = .default
			notificationContent.categoryIdentifier="ERRORS" // Use ERRORS category which has no actions
			let notificationReq=UNNotificationRequest(identifier: "transfer_"+transfer.id, content: notificationContent, trigger: nil)
			UNUserNotificationCenter.current().add(notificationReq)
		} else {
			// Show notification with Accept/Decline buttons
			let notificationContent=UNMutableNotificationContent()
			notificationContent.title="NearDrop"
			notificationContent.subtitle=String(format:NSLocalizedString("PinCode", value: "PIN: %@", comment: ""), arguments: [transfer.pinCode!])
			notificationContent.body=String(format: NSLocalizedString("DeviceSendingFiles", value: "%1$@ is sending you %2$@", comment: ""), arguments: [device.name, fileStr])
			notificationContent.sound = .default
			notificationContent.categoryIdentifier="INCOMING_TRANSFERS"
			notificationContent.userInfo=["transferID": transfer.id]
			let notificationReq=UNNotificationRequest(identifier: "transfer_"+transfer.id, content: notificationContent, trigger: nil)
			UNUserNotificationCenter.current().add(notificationReq)
			self.activeIncomingTransfers[transfer.id]=TransferInfo(device: device, transfer: transfer)
		}
	}
	
	func incomingTransfer(id: String, didFinishWith error: Error?) {
		guard let transfer=self.activeIncomingTransfers[id] else {return}
		if let error=error{
			let notificationContent=UNMutableNotificationContent()
			notificationContent.title=String(format: NSLocalizedString("TransferError", value: "Failed to receive files from %@", comment: ""), arguments: [transfer.device.name])
			if let ne=(error as? NearbyError){
				switch ne{
				case .inputOutput:
					notificationContent.body="I/O Error";
				case .protocolError(_):
					notificationContent.body=NSLocalizedString("Error.Protocol", value: "Communication error", comment: "")
				case .requiredFieldMissing:
					notificationContent.body=NSLocalizedString("Error.Protocol", value: "Communication error", comment: "")
				case .ukey2:
					notificationContent.body=NSLocalizedString("Error.Crypto", value: "Encryption error", comment: "")
				case .canceled(reason: _):
					break; // can't happen for incoming transfers
				}
			}else{
				notificationContent.body=error.localizedDescription
			}
			notificationContent.categoryIdentifier="ERRORS"
			UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "transferError_"+id, content: notificationContent, trigger: nil))
		}
		UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["transfer_"+id])
		self.activeIncomingTransfers.removeValue(forKey: id)
	}
}

struct TransferInfo{
	let device:RemoteDeviceInfo
	let transfer:TransferMetadata
}
