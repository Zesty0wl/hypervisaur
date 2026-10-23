import Foundation

/// Windows Setup reads `autounattend.xml` from the root of removable and fixed disks.
///
/// The answer file always allows setup to proceed with the UEFI firmware that ships with QEMU, which doesn't implement
/// Secure Boot, and lets the user finish setup without a network connection. Just before the first-run setup, it runs
/// the setup script on the drivers disk, which is how Windows gets its network adapter and display driver. Windows Setup
/// itself fails to start if it's given those drivers, so they're only installed once Windows is on the disk.
///
/// With ``WindowsUnattendedSetup``, it also answers everything that Windows Setup and the first-run setup would ask:
/// it installs the preferred edition on the boot disk, creates a local account and signs in to it.
enum WindowsAnswerFile {
    static func xml(setup: WindowsUnattendedSetup? = nil, image: WindowsInstallImage? = nil) -> String {
        let unattended: (setup: WindowsUnattendedSetup, image: WindowsInstallImage, productKey: String)?
        if let setup, let image, let productKey = image.genericProductKey {
            unattended = (setup, image, productKey)
        } else {
            unattended = nil
        }

        var xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <settings pass="windowsPE">

        """

        if let unattended {
            xml += """
                <component name="Microsoft-Windows-International-Core-WinPE" \(componentAttributes)>
                  <SetupUILanguage>
                    <UILanguage>\(unattended.image.defaultLanguage.xmlEscaped)</UILanguage>
                  </SetupUILanguage>
                  <InputLocale>\(unattended.setup.locale.xmlEscaped)</InputLocale>
                  <SystemLocale>\(unattended.setup.locale.xmlEscaped)</SystemLocale>
                  <UILanguage>\(unattended.image.defaultLanguage.xmlEscaped)</UILanguage>
                  <UserLocale>\(unattended.setup.locale.xmlEscaped)</UserLocale>
                </component>

            """
        }

        xml += """
            <component name="Microsoft-Windows-Setup" \(componentAttributes)>

        """

        if let unattended {
            /// The boot disk is the first disk, see ``QEMULaunchConfiguration``.
            xml += """
                  <DiskConfiguration>
                    <Disk wcm:action="add">
                      <DiskID>0</DiskID>
                      <WillWipeDisk>true</WillWipeDisk>
                      <CreatePartitions>
                        <CreatePartition wcm:action="add"><Order>1</Order><Type>EFI</Type><Size>260</Size></CreatePartition>
                        <CreatePartition wcm:action="add"><Order>2</Order><Type>MSR</Type><Size>16</Size></CreatePartition>
                        <CreatePartition wcm:action="add"><Order>3</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>
                      </CreatePartitions>
                      <ModifyPartitions>
                        <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>FAT32</Format><Label>System</Label></ModifyPartition>
                        <ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>3</PartitionID><Format>NTFS</Format><Label>Windows</Label><Letter>C</Letter></ModifyPartition>
                      </ModifyPartitions>
                    </Disk>
                  </DiskConfiguration>
                  <ImageInstall>
                    <OSImage>
                      <InstallFrom>
                        <MetaData wcm:action="add"><Key>/IMAGE/INDEX</Key><Value>\(unattended.image.index)</Value></MetaData>
                      </InstallFrom>
                      <InstallTo><DiskID>0</DiskID><PartitionID>3</PartitionID></InstallTo>
                    </OSImage>
                  </ImageInstall>
                  <UserData>
                    <AcceptEula>true</AcceptEula>
                    <ProductKey><Key>\(unattended.productKey)</Key></ProductKey>
                  </UserData>

            """
        }

        xml += """
              <RunSynchronous>
                <RunSynchronousCommand wcm:action="add">
                  <Order>1</Order>
                  <Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
              </RunSynchronous>
            </component>
          </settings>
          <settings pass="specialize">
            <component name="Microsoft-Windows-Deployment" \(componentAttributes)>
              <RunSynchronous>
                <RunSynchronousCommand wcm:action="add">
                  <Order>1</Order>
                  <Path>reg add HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\OOBE /v BypassNRO /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                  <Order>2</Order>
                  <Path>cmd /c for %d in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do @if exist \(setupScriptPath) call \(setupScriptPath)</Path>
                </RunSynchronousCommand>
              </RunSynchronous>
            </component>
          </settings>

        """

        if let unattended {
            xml += oobeSystemSettings(for: unattended.setup, uiLanguage: unattended.image.defaultLanguage)
        }

        xml += """
        </unattend>

        """

        return xml
    }

    private static let componentAttributes = #"processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS""#

    private static let setupScriptPath = "%d:\\\(WindowsDriversDisk.driversFolderName)\\\(WindowsDriversDisk.setupScriptName)"

    /// Without a password, Windows signs in to the account every time it starts. With one, Windows signs in by itself once,
    /// then removes the password that it keeps for doing so.
    private static func oobeSystemSettings(for setup: WindowsUnattendedSetup, uiLanguage: String) -> String {
        let accountName = setup.accountName.xmlEscaped
        let password = (setup.password ?? "").xmlEscaped
        let logonCount = setup.password == nil ? 999_999 : 1

        var timeZone = ""
        if let name = setup.timeZone {
            timeZone = "\n      <TimeZone>\(name.xmlEscaped)</TimeZone>"
        }

        return """
          <settings pass="oobeSystem">
            <component name="Microsoft-Windows-International-Core" \(componentAttributes)>
              <InputLocale>\(setup.locale.xmlEscaped)</InputLocale>
              <SystemLocale>\(setup.locale.xmlEscaped)</SystemLocale>
              <UILanguage>\(uiLanguage.xmlEscaped)</UILanguage>
              <UserLocale>\(setup.locale.xmlEscaped)</UserLocale>
            </component>
            <component name="Microsoft-Windows-Shell-Setup" \(componentAttributes)>
              <OOBE>
                <HideEULAPage>true</HideEULAPage>
                <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                <HideLocalAccountScreen>true</HideLocalAccountScreen>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <ProtectYourPC>3</ProtectYourPC>
              </OOBE>
              <UserAccounts>
                <LocalAccounts>
                  <LocalAccount wcm:action="add">
                    <Name>\(accountName)</Name>
                    <DisplayName>\(accountName)</DisplayName>
                    <Group>Administrators</Group>
                    <Password><Value>\(password)</Value><PlainText>true</PlainText></Password>
                  </LocalAccount>
                </LocalAccounts>
              </UserAccounts>
              <AutoLogon>
                <Enabled>true</Enabled>
                <Username>\(accountName)</Username>
                <Password><Value>\(password)</Value><PlainText>true</PlainText></Password>
                <LogonCount>\(logonCount)</LogonCount>
              </AutoLogon>\(timeZone)
            </component>
          </settings>

        """
    }
}

private extension String {
    var xmlEscaped: String {
        var escaped = ""
        for character in self {
            switch character {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            case "'": escaped += "&apos;"
            default: escaped.append(character)
            }
        }
        return escaped
    }
}
