//
//  Player.swift
//  Rolik
//
//  Created by Max Mashkov on 1/28/16.
//  Copyright © 2016 TheMindStudios. All rights reserved.
//

import Foundation
import AVFoundation
import CoreMedia

private let kDefaultUpdateTimeInterval = 0.1

// KVO contexts

private var PlayerObserverContext = 0
private var PlayerItemObserverContext = 0

// KVO player keys

private let PlayerRateKey = "rate"
private let PlayerStatusKey = "status"
private let PlayerCurrentItemKey = "currentItem"

// KVO player item keys

private let PlayerItemEmptyBufferKey = "currentItem.playbackBufferEmpty"
private let PlayerItemKeepUp = "currentItem.playbackLikelyToKeepUp"
private let PlayerItemLoadedTimeRanges = "currentItem.playbackLikelyToKeepUp"

// Asset loading keys

private let AssetTracksKey = "tracks"
private let AssetPlayableKey = "playable"
private let AssetDurationKey = "duration"


public enum PlaybackState: Int {
    
    case Stopped = 0
    case Playing
    case Paused
    case Failed
}

public enum BufferingState: Int {
    case Unknown = 0
    case Ready
    case Delayed
}

public enum MediaPlayerLayerResizeMode {
    case Resize
    case ResizeAspect
    case ResizeAspectFill
    
    public var videoGravity: String {
        switch self {
        case .Resize:
            return AVLayerVideoGravityResize
        case .ResizeAspect:
            return AVLayerVideoGravityResizeAspect
        case .ResizeAspectFill:
            return AVLayerVideoGravityResizeAspectFill
        }
    }
    
    public init(videoGravity: String) {
        switch videoGravity {
        case AVLayerVideoGravityResize:
            self = .Resize
        case AVLayerVideoGravityResizeAspect:
            self = .ResizeAspect
        case AVLayerVideoGravityResizeAspectFill:
            self = .ResizeAspectFill
        default:
            self = .Resize
        }
    }
}

public protocol MediaPlayerLayerProvider {
    var playerLayer: AVPlayerLayer { get }
    var resizeMode: MediaPlayerLayerResizeMode { get set }
}

public protocol MediaPlayerDelegate: class {
    func player(player: MediaPlayer, didUpdateTime timePlayed: Float64)
    func player(player: MediaPlayer, didChangePlaybackState playbackState: PlaybackState)
    func playerDidPlayToEnd(player: MediaPlayer)
    func playerDidUpdatePlayerItem(player: MediaPlayer)
}

public protocol MediaPlayerBufferingDelegate: class {
    func player(player: MediaPlayer, didChangeBufferingState bufferingState: BufferingState)
    func playerDidUpdateBufferingProgress(player: MediaPlayer)
}

public class MediaPlayer: NSObject {
    
    public weak var delegate: MediaPlayerDelegate?
    public weak var bufferingDelegate: MediaPlayerBufferingDelegate?
    
    private let player: AVPlayer = {
        let player = AVPlayer()
        
        player.actionAtItemEnd = .Pause
        
        return player
    }()
    
    private var periodicTimeObserver: AnyObject?
    
    public private(set) var playbackState: PlaybackState = .Stopped {
        didSet {
            delegate?.player(self, didChangePlaybackState: playbackState)
        }
    }
    
    public private(set) var bufferingState: BufferingState = .Unknown {
        didSet {
            bufferingDelegate?.player(self, didChangeBufferingState: bufferingState)
        }
    }
    
    public var maximumDuration: NSTimeInterval! {
        if let playerItem = playerItem {
            return playerItem.duration.seconds
        } else {
            return kCMTimeIndefinite.seconds
        }
    }
    
    public var isPlaying: Bool {
        return player.rate > 0.0
    }
    
    public var muted: Bool {
        get {
            return player.muted
        }
        set {
            player.muted = newValue
        }
    }
    
    public var volume: Float {
        get {
            return player.volume
        }
        set {
            player.volume = newValue
        }
    }
    
    public var asset: AVAsset? {
        get {
            return playerItem?.asset
        }
        
        set {
            if isPlaying {
                pause()
            }
            
            if let asset = newValue {
                setupAsset(asset)
            } else {
                setupPlayerItem(nil)
            }
        }
    }

    public var playerItem: AVPlayerItem? {
        get {
            return player.currentItem
        }
        
        set {
            if isPlaying {
                pause()
            }
            
            setupPlayerItem(newValue)
            delegate?.playerDidUpdatePlayerItem(self)
        }
    }
    
    public var URL: NSURL? {
        return (playerItem?.asset as? AVURLAsset)?.URL
    }
    
    public var updateInterval: NSTimeInterval = kDefaultUpdateTimeInterval {
        
        didSet {
            
            setupPeriodicTimeObserver()
        }
    }
    
    public var timePlayed: Float64 {
        
        guard let playerItem = playerItem else {
            return 0.0
        }
        
        let currentTime = playerItem.currentTime()
        
        let currentTimeValue = currentTime.seconds
        
        guard !CMTIME_IS_INVALID(currentTime) && isfinite(currentTimeValue) else {
            return 0.0
        }

        return currentTimeValue
    }
    
    public var timeLeft: Float64 {
        return duration - timePlayed
    }
    
    public var duration: Float64 {
        
        guard let playerItem = playerItem else {
            return 0.0
        }
        
        let playerItemDuration = playerItem.duration
        
        let duration = playerItemDuration.seconds
        
        guard !CMTIME_IS_INVALID(playerItemDuration) && isfinite(duration) else {
            return 0.0
        }
        
        return duration
    }
    
    public var progress: Float {
        guard duration > 0.0 else {
            return 0.0
        }
        
        return Float(timePlayed / duration)
    }
    
    public var bufferingProgress: Float {
        
        guard let playerItem = playerItem else {
            return 0.0
        }
        
        guard duration > 0.0 else {
            return 0.0
        }
        
        guard let loadedTimeRange = playerItem.loadedTimeRanges.first else {
            return 0.0
        }
        
        let loadedDuration = loadedTimeRange.CMTimeRangeValue.duration.seconds
        
        return Float(loadedDuration / duration)
    }
    
    public var startSecond: NSTimeInterval = 0.0 {
        didSet {
            reset()
        }
    }
    
    public var endSecond: NSTimeInterval = 0.0 {
        didSet {
            if let playerItem = playerItem {
                setupEndTimeForPlayerItem(playerItem)
            }
        }
    }
    
    private(set) var isSeeking: Bool = false
    
    
    deinit {
        
        if let periodicTimeObserver = periodicTimeObserver {
            player.removeTimeObserver(periodicTimeObserver)
        }
        
        periodicTimeObserver = nil
        
        NSNotificationCenter.defaultCenter().removeObserver(self)
        player.removeObserver(self, forKeyPath: PlayerRateKey, context: &PlayerObserverContext)
        player.removeObserver(self, forKeyPath: PlayerStatusKey, context: &PlayerObserverContext)
        player.removeObserver(self, forKeyPath: PlayerItemEmptyBufferKey, context: &PlayerItemObserverContext)
        player.removeObserver(self, forKeyPath: PlayerItemKeepUp, context: &PlayerItemObserverContext)
        player.removeObserver(self, forKeyPath: PlayerItemLoadedTimeRanges, context: &PlayerItemObserverContext)
        player.removeObserver(self, forKeyPath: PlayerCurrentItemKey, context: &PlayerObserverContext)
        player.pause()
    }
    
    public override init() {
        super.init()
        
        player.addObserver(self, forKeyPath: PlayerRateKey, options: ([NSKeyValueObservingOptions.New, NSKeyValueObservingOptions.Old]) , context: &PlayerObserverContext)
        player.addObserver(self, forKeyPath: PlayerStatusKey, options: ([NSKeyValueObservingOptions.New, NSKeyValueObservingOptions.Old]) , context: &PlayerObserverContext)
        player.addObserver(self, forKeyPath: PlayerItemEmptyBufferKey, options: ([NSKeyValueObservingOptions.New, NSKeyValueObservingOptions.Old]) , context: &PlayerItemObserverContext)
        player.addObserver(self, forKeyPath: PlayerItemKeepUp, options: ([NSKeyValueObservingOptions.New, NSKeyValueObservingOptions.Old]) , context: &PlayerItemObserverContext)
        player.addObserver(self, forKeyPath: PlayerItemLoadedTimeRanges, options: ([NSKeyValueObservingOptions.New, NSKeyValueObservingOptions.Old]) , context: &PlayerItemObserverContext)
        player.addObserver(self, forKeyPath: PlayerCurrentItemKey, options: ([NSKeyValueObservingOptions.New, NSKeyValueObservingOptions.Old]) , context: &PlayerObserverContext)
        
        updateInterval = kDefaultUpdateTimeInterval
        setupPeriodicTimeObserver()
    }
    
    public func setupPlayerLayer(playerLayer: AVPlayerLayer) {
        playerLayer.player = player
    }
}


public extension MediaPlayer {
    
    override func observeValueForKeyPath(keyPath: String?, ofObject object: AnyObject?, change: [String : AnyObject]?, context: UnsafeMutablePointer<Void>) {
        
        switch (keyPath, context) {
        
        case (.Some(PlayerCurrentItemKey), &PlayerObserverContext):
            
            if startSecond > 0.0 {
                seekToSeconds(startSecond, shouldAutoPlay: false)
            }
            
        case (.Some(PlayerRateKey), &PlayerObserverContext):

            if bufferingState == .Ready {
                playbackState = player.rate > 0 ? .Playing : .Paused
            }
            
        case (.Some(PlayerItemKeepUp), &PlayerItemObserverContext):
            
            bufferingState = .Ready
            if playbackState == .Playing {
                play()
            }
            
        case (.Some(PlayerStatusKey), &PlayerObserverContext):
            
            switch player.status {
            case .Unknown:
                break
            case .ReadyToPlay:
                if playbackState == .Playing {
                    play()
                }
            case .Failed:
                playbackState = .Failed
            }
            
        case (.Some(PlayerItemEmptyBufferKey), &PlayerItemObserverContext):
            
            if let playerItem = playerItem {
                if playerItem.playbackBufferEmpty {
                    bufferingState = .Delayed
                }
            }
            
        case (.Some(PlayerItemLoadedTimeRanges), &PlayerItemObserverContext):
            
            bufferingDelegate?.playerDidUpdateBufferingProgress(self)
            
        default:
            break
        }
    }
}


public extension MediaPlayer {
    
    func togglePlay() {
        isPlaying ? pause() : play()
    }
    
    func play() {
        player.play()
        playbackState = .Playing
    }
    
    func pause() {
        player.pause()
        playbackState = .Paused
    }
    
    func reset() {
        pause()
        seekToSeconds(startSecond, shouldAutoPlay: false)
    }
    
    func seekToSeconds(seconds: Float64, shouldAutoPlay: Bool, completionHandler: ((finished: Bool, wasPlaying: Bool) -> Void)? = nil){
        
        guard let playerItem = playerItem where player.status == .ReadyToPlay else {
            completionHandler?(finished: false, wasPlaying: false)
            return
        }
        
        let seekTime = CMTimeMakeWithSeconds(seconds, playerItem.asset.duration.timescale)
        
        guard CMTIME_IS_VALID(seekTime) else {
            completionHandler?(finished: false, wasPlaying: false)
            return
        }
        
        let wasPlaying = isPlaying
        
        isSeeking = true
        
        playerItem.cancelPendingSeeks()
        
        let tolerance = kCMTimeZero
        playerItem.seekToTime(seekTime, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] finished in
            
            self?.isSeeking = false
            
            if let strongSelf = self {
                strongSelf.delegate?.player(strongSelf, didUpdateTime: strongSelf.timePlayed)
            }
            
            if wasPlaying && shouldAutoPlay {
                self?.play()
            }
            
            completionHandler?(finished: finished, wasPlaying: wasPlaying)
        }

    }
    
    func seekToProgress(progress: Float, shouldAutoPlay: Bool, completionHandler: ((finished: Bool, wasPlaying: Bool) -> Void)? = nil) {
        
        let seconds = Float64(progress) * duration
        
        seekToSeconds(seconds, shouldAutoPlay: shouldAutoPlay, completionHandler: completionHandler)
    }
}


// MARK: - Private

extension MediaPlayer {
    
    private func setupPeriodicTimeObserver() {
        
        if let periodicTimeObserver = periodicTimeObserver {
            player.removeTimeObserver(periodicTimeObserver)
        }
        
        if updateInterval > 0.0 {

            periodicTimeObserver = player.addPeriodicTimeObserverForInterval(CMTimeMakeWithSeconds(updateInterval, Int32(NSEC_PER_SEC)), queue: dispatch_get_main_queue()) { [weak self] time in
                
                self?.timeObserverFired()
            }
        }
    }
    
    private func timeObserverFired() {
        
        guard !isSeeking else {
            return
        }
        
        delegate?.player(self, didUpdateTime: timePlayed)
    }
    
    private func setupAsset(asset: AVAsset) {
        
        if self.playbackState == .Playing {
            self.pause()
        }
        
        bufferingState = .Unknown
        
        let keys: [String] = [AssetTracksKey, AssetPlayableKey, AssetDurationKey]
        
        asset.loadValuesAsynchronouslyForKeys(keys, completionHandler: { [weak self] in
            dispatch_async(dispatch_get_main_queue(), { () -> Void in
                
                guard let strongSelf = self else {
                    return
                }
                
                for key in keys {
                    var error: NSError?
                    let status = asset.statusOfValueForKey(key, error:&error)
                    if status == .Failed {
                        strongSelf.playbackState = .Failed
                        return
                    }
                }
                
                if asset.playable.boolValue == false {
                    strongSelf.playbackState = .Failed
                    return
                }
                
                let playerItem: AVPlayerItem = AVPlayerItem(asset:asset)
                strongSelf.setupPlayerItem(playerItem)
            })
        })
    }
    
    private func setupPlayerItem(playerItem: AVPlayerItem?) {
        
        defer {
            player.replaceCurrentItemWithPlayerItem(playerItem)
        }
        
        if let currentPlayerItem = self.playerItem {
            NSNotificationCenter.defaultCenter().removeObserver(self, name: AVPlayerItemPlaybackStalledNotification, object: currentPlayerItem)
            NSNotificationCenter.defaultCenter().removeObserver(self, name: AVPlayerItemDidPlayToEndTimeNotification, object: currentPlayerItem)
            NSNotificationCenter.defaultCenter().removeObserver(self, name: AVPlayerItemFailedToPlayToEndTimeNotification, object: currentPlayerItem)
        }
        
        guard let playerItem = playerItem else {
            return
        }
        
        setupEndTimeForPlayerItem(playerItem)

        NSNotificationCenter.defaultCenter().addObserver(self, selector: #selector(MediaPlayer.playerItemDidPlayToEndTime(_:)), name: AVPlayerItemDidPlayToEndTimeNotification, object: playerItem)
        NSNotificationCenter.defaultCenter().addObserver(self, selector: #selector(MediaPlayer.playerItemFailedToPlayToEndTime(_:)), name: AVPlayerItemFailedToPlayToEndTimeNotification, object: playerItem)
        NSNotificationCenter.defaultCenter().addObserver(self, selector: #selector(MediaPlayer.playbackDidStall(_:)), name: AVPlayerItemPlaybackStalledNotification, object: playerItem)
    }
    
    private func setupEndTimeForPlayerItem(playerItem: AVPlayerItem) {
        if endSecond > 0.0 {
            playerItem.forwardPlaybackEndTime = CMTimeMakeWithSeconds(endSecond, playerItem.asset.duration.timescale)
        } else {
            playerItem.forwardPlaybackEndTime = kCMTimeInvalid
        }
    }
}

extension MediaPlayer {
    
    // MARK: - Notifications
    
    @objc private func playerItemDidPlayToEndTime(aNotification: NSNotification) {
        playbackState = .Stopped
        delegate?.playerDidPlayToEnd(self)
        
        reset()
    }
    
    @objc private func playerItemFailedToPlayToEndTime(aNotification: NSNotification) {
        playbackState = .Failed
    }
    
    @objc private func playbackDidStall(notification: NSNotification) {
        bufferingState = .Delayed
    }
}

