### 生产者：消费者=1：1

```
	rand.Seed(time.Now().UnixNano()) // needed before Go 1.20
	log.SetFlags(0)

	// ...
	const Max = 100000
	const NumReceivers = 100

	wgReceivers := sync.WaitGroup{}
	wgReceivers.Add(NumReceivers)

	// ...
	dataCh := make(chan int)

	// the sender
	go func() {
		for {
			if value := rand.Intn(Max); value == 0 {
				// The only sender can close the
				// channel at any time safely.
				close(dataCh)
				return
			} else {
				dataCh <- value
			}
		}
	}()

	// receivers
	for i := 0; i < NumReceivers; i++ {
		go func() {
			defer wgReceivers.Done()

			// Receive values until dataCh is
			// closed and the value buffer queue
			// of dataCh becomes empty.
			for value := range dataCh {
				log.Println(value)
			}
		}()
	}

	wgReceivers.Wait()
```

### 生产者：消费者=1：N

```
// 生产者：消费者=1：N
	chanInt := make(chan int)
	wg := sync.WaitGroup{}
	wg.Add(3)
	//生产者1个
	go func(ci chan int) {
		defer wg.Done()
		defer log.Println("生产者1 over")

		for i := 0; i < 10; i++ {
			chanInt <- i
		}
		//关闭channel
		close(chanInt)

	}(chanInt)

	//消费者1个
	go func(ci chan int) {
		defer wg.Done()
		defer log.Println("消费者1 over")

		for v := range ci {
			log.Println(v)
		}
	}(chanInt)
	go func(ci chan int) {
		defer wg.Done()
		defer log.Println("消费者2 over")

		for v := range ci {
			log.Println(v)
		}
	}(chanInt)

	wg.Wait()
	log.Print("main over")

```

### 生产者：消费者=N：1

```
	rand.Seed(time.Now().UnixNano()) // needed before Go 1.20
	log.SetFlags(0)

	// ...
	const Max = 100000
	const NumSenders = 1000

	wgReceivers := sync.WaitGroup{}
	wgReceivers.Add(1)

	// ...
	dataCh := make(chan int)
	stopCh := make(chan struct{})
	// stopCh is an additional signal channel.
	// Its sender is the receiver of channel
	// dataCh, and its receivers are the
	// senders of channel dataCh.

	// senders
	for i := 0; i < NumSenders; i++ {
		go func() {
			for {
				// The try-receive operation is to try
				// to exit the goroutine as early as
				// possible. For this specified example,
				// it is not essential.
				//select {
				//case <-stopCh:
				//	return
				//default:
				//}

				// Even if stopCh is closed, the first
				// branch in the second select may be
				// still not selected for some loops if
				// the send to dataCh is also unblocked.
				// But this is acceptable for this
				// example, so the first select block
				// above can be omitted.
				select {
				case <-stopCh:
					return
				case dataCh <- rand.Intn(Max):
				}
			}
		}()
	}

	// the receiver
	go func() {
		defer wgReceivers.Done()

		for value := range dataCh {
			if value == Max-1 {
				// The receiver of channel dataCh is
				// also the sender of stopCh. It is
				// safe to close the stop channel here.
				close(stopCh)
				return
			}

			log.Println(value)
		}
	}()

	// ...
	wgReceivers.Wait()
```



### 生产者：消费者=n:m

````
rand.Seed(time.Now().UnixNano()) // needed before Go 1.20
	log.SetFlags(0)

	// ...
	const Max = 100000
	const NumReceivers = 10
	const NumSenders = 1000

	wgReceivers := sync.WaitGroup{}
	wgReceivers.Add(NumReceivers)

	// ...
	dataCh := make(chan int)
	stopCh := make(chan struct{})
	// stopCh is an additional signal channel.
	// Its sender is the moderator goroutine shown
	// below, and its receivers are all senders
	// and receivers of dataCh.
	toStop := make(chan string, 1)
	// The channel toStop is used to notify the
	// moderator to close the additional signal
	// channel (stopCh). Its senders are any senders
	// and receivers of dataCh, and its receiver is
	// the moderator goroutine shown below.
	// It must be a buffered channel.

	var stoppedBy string

	// moderator
	go func() {
		stoppedBy = <-toStop
		close(stopCh)
	}()

	// senders
	for i := 0; i < NumSenders; i++ {
		go func(id string) {
			for {
				value := rand.Intn(Max)
				if value == 0 {
					// Here, the try-send operation is
					// to notify the moderator to close
					// the additional signal channel.
					select {
					case toStop <- "sender#" + id:
					default:
					}
					return
				}

				// The try-receive operation here is to
				// try to exit the sender goroutine as
				// early as possible. Try-receive and
				// try-send select blocks are specially
				// optimized by the standard Go
				// compiler, so they are very efficient.
				//select {
				//case <-stopCh:
				//	return
				//default:
				//}

				// Even if stopCh is closed, the first
				// branch in this select block might be
				// still not selected for some loops
				// (and for ever in theory) if the send
				// to dataCh is also non-blocking. If
				// this is unacceptable, then the above
				// try-receive operation is essential.
				select {
				case <-stopCh:
					return
				case dataCh <- value:
				}
			}
		}(strconv.Itoa(i))
	}

	// receivers
	for i := 0; i < NumReceivers; i++ {
		go func(id string) {
			defer wgReceivers.Done()

			for {
				// Same as the sender goroutine, the
				// try-receive operation here is to
				// try to exit the receiver goroutine
				// as early as possible.
				//select {
				//case <-stopCh:
				//	return
				//default:
				//}

				// Even if stopCh is closed, the first
				// branch in this select block might be
				// still not selected for some loops
				// (and forever in theory) if the receive
				// from dataCh is also non-blocking. If
				// this is not acceptable, then the above
				// try-receive operation is essential.
				select {
				case <-stopCh:
					return
				case value := <-dataCh:
					if value == Max-1 {
						// Here, the same trick is
						// used to notify the moderator
						// to close the additional
						// signal channel.
						select {
						case toStop <- "receiver#" + id:
						default:
						}
						return
					}

					log.Println(value)
				}
			}
		}(strconv.Itoa(i))
	}

	// ...
	wgReceivers.Wait()
	log.Println("stopped by", stoppedBy)
```
