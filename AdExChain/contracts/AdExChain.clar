;; Decentralized Ad Auction with Intelligent Bidding
;; A secure smart contract for running decentralized advertising auctions with automated
;; bidding strategies, reputation-based ranking, fraud detection, and fair revenue
;; distribution between publishers, advertisers, and the platform ecosystem.

;; constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-UNAUTHORIZED (err u400))
(define-constant ERR-AUCTION-NOT-FOUND (err u401))
(define-constant ERR-AUCTION-ENDED (err u402))
(define-constant ERR-INSUFFICIENT-BALANCE (err u403))
(define-constant ERR-INVALID-BID (err u404))
(define-constant ERR-AD-NOT-APPROVED (err u405))
(define-constant ERR-PUBLISHER-NOT-VERIFIED (err u406))
(define-constant MIN-BID-AMOUNT u100000) ;; 0.1 STX minimum bid
(define-constant AUCTION-DURATION u144) ;; ~24 hours in blocks
(define-constant PLATFORM-FEE-PERCENTAGE u300) ;; 3% platform fee
(define-constant QUALITY-SCORE-MULTIPLIER u150) ;; 1.5x for high quality ads
(define-constant FRAUD-DETECTION-THRESHOLD u80) ;; 80% fraud confidence threshold

;; data maps and vars
(define-data-var next-auction-id uint u1)
(define-data-var total-platform-revenue uint u0)
(define-data-var active-auctions-count uint u0)

(define-map ad-auctions
  uint
  {
    publisher: principal,
    ad-slot-category: (string-ascii 50),
    target-demographics: (string-ascii 100),
    start-block: uint,
    end-block: uint,
    minimum-bid: uint,
    winning-bid: uint,
    winning-bidder: (optional principal),
    status: (string-ascii 20), ;; ACTIVE, ENDED, SETTLED
    total-impressions: uint,
    click-through-rate: uint
  })

(define-map advertiser-profiles
  principal
  {
    reputation-score: uint,
    total-spent: uint,
    successful-campaigns: uint,
    fraud-incidents: uint,
    quality-score: uint,
    automated-bidding-enabled: bool,
    max-daily-budget: uint,
    current-daily-spent: uint
  })

(define-map auction-bids
  {auction-id: uint, bidder: principal}
  {
    bid-amount: uint,
    bid-timestamp: uint,
    quality-adjusted-bid: uint,
    automated-bid: bool
  })

(define-map publisher-verification
  principal
  {
    verified: bool,
    domain-authority: uint,
    monthly-traffic: uint,
    content-quality-score: uint,
    payout-address: principal
  })

;; private functions
(define-private (calculate-quality-adjusted-bid (bid-amount uint) (advertiser principal))
  (let ((profile (default-to 
                   {reputation-score: u500, total-spent: u0, successful-campaigns: u0, 
                    fraud-incidents: u0, quality-score: u500, automated-bidding-enabled: false,
                    max-daily-budget: u0, current-daily-spent: u0}
                   (map-get? advertiser-profiles advertiser))))
    (let ((quality-multiplier (if (> (get quality-score profile) u700)
                                QUALITY-SCORE-MULTIPLIER
                                u100)))
      (/ (* bid-amount quality-multiplier) u100))))

(define-private (detect-bid-fraud (bidder principal) (bid-amount uint) (auction-id uint))
  (let ((profile (map-get? advertiser-profiles bidder)))
    (match profile
      some-profile
        (let ((avg-bid (if (> (get successful-campaigns some-profile) u0)
                         (/ (get total-spent some-profile) (get successful-campaigns some-profile))
                         u0))
              (bid-deviation (if (> avg-bid u0) 
                              (let ((difference (if (>= bid-amount avg-bid)
                                                  (- bid-amount avg-bid)
                                                  (- avg-bid bid-amount))))
                                (/ (* difference u100) avg-bid))
                              u0))
              (fraud-history-weight (* (get fraud-incidents some-profile) u20)))
          (+ bid-deviation fraud-history-weight))
      u0)))

(define-private (abs (n int))
  (if (< n 0) (* n -1) n))

(define-private (execute-platform-fee-collection (auction-revenue uint))
  (let ((platform-fee (/ (* auction-revenue PLATFORM-FEE-PERCENTAGE) u10000)))
    (var-set total-platform-revenue (+ (var-get total-platform-revenue) platform-fee))
    platform-fee))

;; public functions
(define-public (register-advertiser (max-daily-budget uint) (enable-auto-bidding bool))
  (begin
    (map-set advertiser-profiles tx-sender {
      reputation-score: u500,
      total-spent: u0,
      successful-campaigns: u0,
      fraud-incidents: u0,
      quality-score: u500,
      automated-bidding-enabled: enable-auto-bidding,
      max-daily-budget: max-daily-budget,
      current-daily-spent: u0
    })
    (ok true)))

(define-public (verify-publisher 
  (publisher principal)
  (domain-authority uint)
  (monthly-traffic uint)
  (content-quality uint))
  
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
    (map-set publisher-verification publisher {
      verified: true,
      domain-authority: domain-authority,
      monthly-traffic: monthly-traffic,
      content-quality-score: content-quality,
      payout-address: publisher
    })
    (ok true)))

(define-public (create-ad-auction
  (ad-slot-category (string-ascii 50))
  (target-demographics (string-ascii 100))
  (minimum-bid uint))
  
  (let ((auction-id (var-get next-auction-id))
        (publisher-info (unwrap! (map-get? publisher-verification tx-sender) ERR-PUBLISHER-NOT-VERIFIED)))
    
    (asserts! (get verified publisher-info) ERR-PUBLISHER-NOT-VERIFIED)
    (asserts! (>= minimum-bid MIN-BID-AMOUNT) ERR-INVALID-BID)
    
    (map-set ad-auctions auction-id {
      publisher: tx-sender,
      ad-slot-category: ad-slot-category,
      target-demographics: target-demographics,
      start-block: block-height,
      end-block: (+ block-height AUCTION-DURATION),
      minimum-bid: minimum-bid,
      winning-bid: u0,
      winning-bidder: none,
      status: "ACTIVE",
      total-impressions: u0,
      click-through-rate: u0
    })
    
    (var-set next-auction-id (+ auction-id u1))
    (var-set active-auctions-count (+ (var-get active-auctions-count) u1))
    (ok auction-id)))

(define-public (place-bid (auction-id uint) (bid-amount uint))
  (let ((auction (unwrap! (map-get? ad-auctions auction-id) ERR-AUCTION-NOT-FOUND))
        (advertiser-profile (unwrap! (map-get? advertiser-profiles tx-sender) ERR-UNAUTHORIZED)))
    
    (asserts! (is-eq (get status auction) "ACTIVE") ERR-AUCTION-ENDED)
    (asserts! (< block-height (get end-block auction)) ERR-AUCTION-ENDED)
    (asserts! (>= bid-amount (get minimum-bid auction)) ERR-INVALID-BID)
    (asserts! (<= (+ (get current-daily-spent advertiser-profile) bid-amount)
                  (get max-daily-budget advertiser-profile)) ERR-INSUFFICIENT-BALANCE)
    
    ;; Fraud detection
    (let ((fraud-score (detect-bid-fraud tx-sender bid-amount auction-id)))
      (asserts! (< fraud-score FRAUD-DETECTION-THRESHOLD) ERR-INVALID-BID)
      
      (let ((quality-adjusted-bid (calculate-quality-adjusted-bid bid-amount tx-sender)))
        ;; Update auction if this is the highest quality-adjusted bid
        (if (> quality-adjusted-bid (get winning-bid auction))
          (map-set ad-auctions auction-id
                   (merge auction {
                     winning-bid: quality-adjusted-bid,
                     winning-bidder: (some tx-sender)
                   }))
          true)
        
        ;; Record the bid
        (map-set auction-bids {auction-id: auction-id, bidder: tx-sender} {
          bid-amount: bid-amount,
          bid-timestamp: block-height,
          quality-adjusted-bid: quality-adjusted-bid,
          automated-bid: false
        })
        
        ;; Update advertiser daily spending
        (map-set advertiser-profiles tx-sender
                 (merge advertiser-profile {
                   current-daily-spent: (+ (get current-daily-spent advertiser-profile) bid-amount)
                 }))
        
        (ok quality-adjusted-bid)))))


