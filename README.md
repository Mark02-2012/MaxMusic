[YTMU+Latest]: https://github.com/Mark02-2012/MaxMusic/releases/download/MaxMusic_9.37.2_2.4.1_(93)/MaxMusic_2.4.1_9.37.2.ipa

[YTMUlatest]: https://github.com/Mark02-2012/MaxMusic/releases/download/YTMU_9.37.2_2.4.1_(95)/YTMusicUltimate_2.4.1_9.37.2.ipa

[YTMU+no-YMP]: https://github.com/Mark02-2012/MaxMusic/releases/download/MaxMusic_9.37.2_2.4.1_(94)/MaxMusic_no_YMP_2.4.1_9.37.2.ipa

<h1 p align="center">MaxMusic (ex YTMUltimate+)</h1>
   
<p align="center">
<td><img src="Resources/IMG_5914.png" width=500


<p align="center">
<img src=https://user-images.githubusercontent.com/38832025/235781207-6d1ad44e-0c32-4aec-9c75-cb928ca8a0d3.png?raw=true) />
</p>

<p align="center">
The best fork of YTMusicUltimate that adds more tweaks for the YouTube Music app on iOS.

<h2 p align="center">Disclaimer</h2>
<p align="center">
   This project is an independent developer modification and is not affiliated with, authorized, maintained, sponsored, or endorsed by Google LLC or YouTube Music. All product and company names are trademarks of their respective holders.

<h2 p align="center">More info</h2>
<p align="center">
   The updates will be released every new YTMusic/YTMusicUltimate version (stimated time for updates: 3-24 hours; VARIABLE), but also ON MY NEW TELEGRAM CHANNEL 👉<a href="https://t.me/Mark02workshop_official">LINK TO JOIN</a>👈

<p align="center">
   <a href="#so-what-is-ytmultimate">More info about YTMUltimate+</a>

## Bug reporting
**In the repo may be some issues, so please report any issue in the [Issues](https://github.com/Mark02-2012/YTMUltimatePLUS/issues) section.**

## Download table
Implemented new fixed deb for working downloads from release 9.23.4 and 2.4.1! (Also in Actions)
| Release | YTM version | YTMUltimate version | MaxMusic version |
| :--- | :---: | :---: | :---: |
| [MaxMusic Latest][YTMU+Latest] | 9.37.2 | 2.4.1 fix | 1.1 |
| [MaxMusic without YouMusicPiP][YTMU+no-YMP] | 9.37.2 | 2.4.1 fix | 1.1 no YouMusicPiP |
| [YTMusicUltimate Latest][YTMULatest] | 9.37.2 | 2.4.1 fix | / |


## Download Links

* **Jailbreak (Only YTMusicUltimate) DEPRECATED, WILL FIX:**
Add __[https://ginsu.dev/repo](https://ginsu.dev/repo)__ to your favorite installer and download latest version from __[Releases](https://github.com/ginsudev/YTMusicUltimate/releases)__ page.

(arm.deb version for Rootful and arm64.deb version for Rootless devices)

* **Sideloading:**
You can find pre-built IPAs in the [Download table](#download-table) and the [releases tab](https://github.com/Mark02-2012/YTMusicUltimate/releases), but can also build one yourself, keep reading:

## How to build a YTMusicUltimate and MaxMusic IPA by yourself using Github actions

>[!NOTE]
>If this is your first time here, start from step 1.
>
>If you already forked my repository and built an IPA before, skip steps 1 and 2. Instead, click on the "Sync fork" button to get the latest version of the tweaks and continue through step 3.

1. Fork this repository using the fork button on the top right.
2. On your forked repository, go to Repository Settings > Actions, enable Read and Write permissions.
3. Go to the Actions tab on your forked repo, click on "Build and Release YTMusicUltimate and MaxMusic" located on the left side. Click "Run workflow" button located on the right side.
4. Find a decrypted YTMusic .ipa file (read [this](#how-to-find-decrypted-youtube-music-ipas) if you don't know where to find one) and upload it to a file provider (filebin.net, Dropbox or catbox.moe is recommended; IF YOU USED DROPBOX, YOU HAVE TO CHANGE THE FINAL PART OF THE LINK FROM dl=0 TO dl=1). Paste the url to the necessary field, select the extra tweaks you want and click "Run workflow".
5. Wait for the build to finish. You can download the tweaked IPA from the releases section of your forked repo. (If you can't find the releases section, go to your forked repo and add /releases to the url. i.e github.com/user/YTMUltimatePLUS/releases)

## How to find decrypted YouTube Music IPAs

**If you have Telegram:**
1. Open Telegram
2. Search for "Eevee IPA Decrypter bot"
3. Start the bot and send him the link for YouTube Music on App Store
4. He will send you the latest YouTube Music decrypted IPA

**If you don't have Telegram/want another version of YouTube Music:**
> [!NOTE]
> For this make sure to disable all adblocks you have (NextDNS, ADGuard, Brave Shields, uBlock Origin etc.)

1. Open your browser and search "Decrypt Day"
2. Click the first link (It should be like decrypt . day the link, without spaces of course)
3. On the search bar, type "YouTube Music", click on "Search" and YouTube Music
4. Scroll down and click on "Download for free" to download the latest available version immediately, click on "Previous versions" instead to download older versions

## IPA building troubleshooting (I can't build the IPA/Github action fails/I can't find the releases section etc.)

99.9% of the time, the culprit is the IPA URL you provided. You HAVE TO provide a decryped IPA. It cannot be any other extension, it has to be a **.ipa** file. Find a decrypted YTMusic IPA (refer to [this](#how-to-find-decrypted-youtube-music-ipas)), upload it to filebin.net, Dropbox or catbox.moe (IF YOU USED DROPBOX, YOU HAVE TO CHANGE THE FINAL PART OF THE LINK FROM dl=0 TO dl=1), give the direct link to the GitHub action. If you find a working ipa and upload it properly, everything will start working perfectly, pinky promise.

If the github action works and you cannot find where you can download the result, you need to add /releases to the url of your forked repository. It'll probably look like this: https://github.com/YOURUSERNAME/YTMUltimatePLUS/releases, don't forget to replace the YOURUSERNAME part with your username on GitHub. It may seem invisible but if the github action is successful, IPA will be there as a draft relelase.

## So.. What is MaxMusic?
MaxMusic is simply a fork of the original [YTMusicUltimate](https://github.com/Dayanch96/YTMusicUltimate) by [Dayanch96](https://github.com/Dayanch96), but with more integrated tweaks and with downloads fixed in newer YTMusic versions.

## MaxMusic versions changelog
 * **1.0 (May 29 2026)**:
  <p>First release, added Return-YouTube-Music-Dislikes, YTMABConfig, YouMusicPiP and VolumeBoostYT</p>
  
 * **1.1 (September 1 2026)**:
   <p>Changed name from YTMUltimate+ to MaxMusic</p>

## Added tweaks
>[!NOTE]
>All added tweaks preferences can be found in YTMusic > Account > Settings, except for VolumeBoostYT and YouMusicPiP (Because them don't have a preferences section in settings).
>
>YTMusicUltimate preferences can be
found in YTMusic > Account.
  
 <details>
  <summary>Return-YouTube-Music-Dislikes</summary>
   <p>Return-YouTube-Music-Dislikes is a tweak based on Return-YouTube-Dislikes that permit to view dislikes in YouTube Music app</p>
     <p><a href="https://github.com/PoomSmart/Return-YouTube-Music-Dislikes">Official repository</a> by <a href="https://github.com/PoomSmart">PoomSmart</a></p>
   </details>

  <details>
   <summary>YTMABConfig</summary>
    <p>YTMABConfig is a tweak that permit to view and change A/B flags of YouTube Music</p>
     <p><a href="https://github.com/PoomSmart/YTMABConfig">Official repository</a> by <a href="https://github.com/PoomSmart">PoomSmart</a></p>
  </details>

  <details>
   <summary>YouMusicPiP</summary>
   <p>YouMusicPiP is a tweak based on YouPiP that enable PiP in YouTube Music when you select video mode on the song and exit from the app</p>
     <p><a href="https://github.com/PoomSmart/YouMusicPiP">Official repository</a> by <a href="https://github.com/PoomSmart">PoomSmart</a></p>
  </details>

   <details>
     <summary>VolumeBoostYT</summary>
     <p>VolumeBoostYT is a tweak that was created for YouTube, but it's also compatible with YouTube Music, that permit to adjust and boost your volume from 0 to 2000% with gestures</p>
     <p><a href="https://github.com/VasirakCalgux/VolumeBoostYT">Official repository</a> by <a href="https://github.com/VasirakCalgux">VasirakCalgux</a></p>
   </details>
